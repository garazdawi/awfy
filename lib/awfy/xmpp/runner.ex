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
  alias Awfy.Xmpp.{Amoc, ScenarioConfig, Topology}

  @doc """
  Run the named scenario end-to-end. On success returns the per-second
  throughput samples plus a `%Benchee.Suite{}` ready to write_term to
  a `.benchee` file. The caller is responsible for serialisation +
  surrounding `meta.json` so the same shape can be reused for other
  application benchmarks (network-bench Phase 2).
  """
  @spec run(String.t(), :local | :aws_clt, keyword()) ::
          {:ok, %{samples: [non_neg_integer()], suite: struct(), config: ScenarioConfig.t()}}
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
         :ok <- delay("ramp-up", config.delay_before_s, log),
         {:ok, samples} <- sample(state, config, log),
         :ok <- delay("cool-down", config.delay_after_s, log) do
      suite =
        Result.build(samples, scenario_name,
          job_name: scenario_name,
          metadata: %{
            "xmpp" => %{
              "scenario" => scenario_name,
              "topology" => to_string(state.topology),
              "users" => config.users,
              "domains" => config.domains,
              "interarrival_ms" => config.interarrival_ms,
              "measurement_duration_s" => config.measurement_duration_s,
              "samples_collected" => length(samples)
            }
          }
        )

      {:ok, %{samples: samples, suite: suite, config: config}}
    end
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

  defp sample(state, %ScenarioConfig{measurement_duration_s: secs} = config, log) do
    log.("sampling messages_sent for #{secs}s")
    samples = Amoc.sample_throughput(state, config)
    log.("collected #{length(samples)} samples")
    {:ok, samples}
  end

  defp log_fn(opts) do
    case Keyword.get(opts, :log, :default) do
      :silent -> fn _ -> :ok end
      :default -> fn msg -> Mix.shell().info("[xmpp] " <> msg) end
      fun when is_function(fun, 1) -> fun
    end
  end
end
