# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Xmpp.Runner do
  @moduledoc """
  Orchestrate one XMPP application-bench run end-to-end:

      load config → deploy topology → wait broker ready
      → start Amoc scenario → ramp-up delay
      → sample `messages_sent` throughput for `measurement_duration_s`
      → cool-down delay → teardown
      → build %Benchee.Suite{} from the sample stream

  Teardown is best-effort and always attempted: a deploy failure mid-run
  shouldn't leave a half-built compose project behind that breaks the
  next invocation.
  """

  alias Awfy.AppBench.Result
  alias Awfy.Xmpp.{Amoc, DockerStats, ScenarioConfig, Topology}

  @doc """
  Run the named scenario end-to-end. On success returns the per-second
  throughput samples plus a `%Benchee.Suite{}` ready to write_term to
  a `.benchee` file. The caller is responsible for serialisation +
  surrounding `meta.json` so the same shape can be reused for other
  application benchmarks (network-bench Phase 2).
  """
  @spec run(String.t(), :local | :aws_clt, keyword()) ::
          {:ok,
           %{
             throughput: [non_neg_integer()],
             cpu_pct: [float()],
             mem_mb: [float()],
             suite: struct(),
             config: ScenarioConfig.t()
           }}
          | {:error, term()}
  def run(scenario_name, topology_tag, opts \\ [])
      when is_binary(scenario_name) and topology_tag in [:local, :aws_clt] do
    log = log_fn(opts)

    with {:ok, config} <- ScenarioConfig.load(scenario_name, topology_tag),
         _ = log.("loaded config: users=#{config.users} domains=#{config.domains}"),
         {:ok, state} <- Topology.deploy(topology_tag, config) do
      try do
        run_inside_topology(state, config, scenario_name, log)
      after
        log.("tearing down topology")
        Topology.teardown(state)
      end
    end
  end

  defp run_inside_topology(state, config, scenario_name, log) do
    with :ok <- wait_ready(state, log),
         :ok <- log_and_start(state, config, log),
         :ok <- delay("ramp-up", config.pre_sampling_wait_s, log),
         {:ok, %{throughput: thr, cpu_pct: cpu, mem_mb: mem}} <- sample(state, config, log),
         :ok <- delay("cool-down", config.delay_after_s, log) do
      suite = build_suite(scenario_name, state, config, thr, cpu, mem)
      {:ok, %{throughput: thr, cpu_pct: cpu, mem_mb: mem, suite: suite, config: config}}
    end
  end

  # Build a three-scenario suite from the run's streams. CPU% and
  # mem_mb are the headline trend signals (lower = faster, matches
  # ESL's own MongooseIM measurement convention); throughput is a
  # sanity-check scenario so the dashboard can show whether we
  # actually drove the configured offered load.
  defp build_suite(scenario_name, state, config, thr, cpu, mem) do
    metadata = %{
      "xmpp" => %{
        "scenario" => scenario_name,
        "topology" => to_string(state.topology),
        "users" => config.users,
        "domains" => config.domains,
        "interarrival_ms" => config.interarrival_ms,
        "measurement_duration_s" => config.measurement_duration_s,
        "throughput_samples_collected" => length(thr),
        "cpu_mem_samples_collected" => length(cpu)
      }
    }

    # Names follow the AWFY dashboard convention `<benchmark>/<lang>`
    # so `Awfy.Compare.Data.parse_name/1` carves them into a
    # benchmark + lang pair. Each metric becomes its own benchmark
    # cell on the dashboard (`xmpp_cpu`, `xmpp_mem`, `xmpp_speed`)
    # under the shared `xmpp` family — they'd otherwise collide on
    # the same (benchmark, lang) key and only the last would
    # render. Short, suite-neutral names (not the Amoc scenario's
    # `dynamic_domains_pm` prefix) so the per-bench page titles
    # fit the dashboard's other entries. The Amoc scenario name
    # is kept separately in the `xmpp.scenario` metadata field
    # so a future second scenario can co-exist on the dashboard
    # without renaming this family.
    Result.build_multi(
      [
        {"xmpp_cpu/erlang", cpu, [unit: :lower_better_raw]},
        {"xmpp_mem/erlang", mem, [unit: :lower_better_raw]},
        {"xmpp_speed/erlang", thr, [unit: :throughput_per_s]}
      ],
      metadata: metadata
    )
  end

  defp wait_ready(state, log) do
    log.("waiting for broker to be ready")

    case Topology.wait_ready(state, 120_000) do
      :ok ->
        log.("broker ready")
        :ok

      {:error, :timeout} = err ->
        log.("broker did not become ready within 120s")
        err
    end
  end

  defp log_and_start(state, config, log) do
    log.("starting scenario #{config.scenario} (#{config.users} users)")
    Amoc.start_scenario(state, config)
  end

  defp delay(_label, 0, _log), do: :ok

  defp delay(label, seconds, log) do
    log.("#{label}: sleeping #{seconds}s")
    Process.sleep(seconds * 1_000)
    :ok
  end

  # Sample all three streams in parallel for the configured measurement
  # window: per-second throughput delta from amoc's `messages_sent`
  # counter, and per-second CPU% + memory MB from `docker stats` on
  # the broker container. Throughput is the sanity-check signal — the
  # CPU/mem series are the AWFY trend signals (ESL's MongooseIM team
  # measures the same way; with a fixed offered load, "how much CPU
  # does the broker need" is a cleaner regression signal than "how
  # many msgs/s sustained").
  defp sample(state, %ScenarioConfig{measurement_duration_s: secs} = config, log) do
    log.("sampling throughput + docker stats for #{secs}s")
    deadline = System.monotonic_time(:millisecond) + secs * 1_000

    throughput_task = Task.async(fn -> Amoc.sample_throughput(state, config) end)

    stats_task =
      Task.async(fn ->
        DockerStats.sample_until(broker_containers(state), deadline)
      end)

    thr = Task.await(throughput_task, secs * 1_000 + 30_000)
    {cpu, mem} = Task.await(stats_task, secs * 1_000 + 30_000)

    log.("collected #{length(thr)} throughput / #{length(cpu)} cpu+mem samples")
    {:ok, %{throughput: thr, cpu_pct: cpu, mem_mb: mem}}
  end

  # Topology State carries the full broker list (3 nodes on :local
  # for the CETS cluster, 3+ on :aws_clt). DockerStats sums per-second
  # CPU%/mem across the list so the dashboard's trend signal is the
  # cluster aggregate, not one node's slice. Falls through to a
  # single-broker default when the state pre-dates the broker_containers
  # field (kept for defensive decoding of any stored State maps in
  # tests).
  defp broker_containers(%Topology.State{broker_containers: list}) when is_list(list) and list != [],
    do: list

  defp broker_containers(%Topology.State{topology: :local}), do: ["awfy-mongooseim-1"]
  defp broker_containers(%Topology.State{topology: :aws_clt}), do: ["awfy-mongooseim-1"]

  defp log_fn(opts) do
    case Keyword.get(opts, :log, :default) do
      :silent -> fn _ -> :ok end
      :default -> fn msg -> Mix.shell().info("[xmpp] " <> msg) end
      fun when is_function(fun, 1) -> fun
    end
  end
end
