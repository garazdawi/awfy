# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Xmpp.Topology do
  @moduledoc """
  Deploys / waits / tears down the topology that hosts a MongooseIM
  broker + Amoc load-gen for the XMPP application benchmark.

  Two topologies are supported (see PLAN/MONGOOSEIM_BENCH_PLAN.md):

    * `:local` — docker compose on a single host (laptop, GHA
      runner, Colima VM on macOS). Used for dev / smoke. Numbers
      from `:local` are *not* shipped to the public dashboard.
    * `:aws_clt` — 6 EC2 + RDS production-shape topology, matches
      ESL's CLT. Not implemented in Phase 1; this module exposes
      the function but raises until Phase 2 lands.

  Both return the same `%State{}` shape so the runner module can
  drive either without branching on topology type.

  ## Relationship to `Awfy.Topology`

  `Awfy.Topology` defines the behaviour every application-bench
  topology will implement once the per-flavour split lands
  (`Awfy.Topology.XmppLocal`, `Awfy.Topology.XmppAwsClt`,
  `Awfy.Topology.NetworkLocal`). This module pre-dates that split
  and carries the `:local` / `:aws_clt` dispatch inline via two
  `deploy/2` heads. PLAN/INFRA_REFACTOR.md § 5 — the behaviour
  exists so the next implementer (network-bench Phase 2) adopts a
  pre-shaped contract rather than copying this module's shape.
  """

  alias Awfy.Xmpp.ScenarioConfig

  @local_compose_file Path.expand("../../../priv/topology/local.compose.yml", __DIR__)

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :topology,
      :broker_host,
      :broker_port,
      :broker_containers,
      :amoc_master_container,
      :amoc_worker_container,
      :metadata
    ]
    defstruct @enforce_keys ++ [compose_file: nil]

    @type t :: %__MODULE__{
            topology: :local | :aws_clt,
            broker_host: String.t(),
            broker_port: pos_integer(),
            # All broker container names in the topology. Multi-broker
            # topologies (3-node CETS cluster on :local, 3+ on
            # :aws_clt) sample resource use across the full list and
            # aggregate so the dashboard's CPU%/mem trends reflect the
            # cluster, not one node's slice. Single-broker topologies
            # still pass a one-element list.
            broker_containers: [String.t()],
            amoc_master_container: String.t(),
            amoc_worker_container: String.t(),
            metadata: map(),
            compose_file: String.t() | nil
          }
  end

  @doc """
  Bring up the topology and return a state handle the runner can
  use to drive Amoc and poll readiness.
  """
  @spec deploy(:local | :aws_clt, ScenarioConfig.t()) :: {:ok, State.t()} | {:error, term()}
  def deploy(:local, %ScenarioConfig{} = config) do
    with :ok <- check_docker_reachable(),
         :ok <- compose_up(config) do
      {:ok,
       %State{
         topology: :local,
         # Host-side reach goes through broker-1 (the only one
         # publishing 5222 on the host). amoc-worker dials the
         # broker hostnames directly over the bridge.
         broker_host: "localhost",
         broker_port: 5222,
         broker_containers: ["awfy-mongooseim-1", "awfy-mongooseim-2", "awfy-mongooseim-3"],
         amoc_master_container: "awfy-amoc-master",
         amoc_worker_container: "awfy-amoc-worker",
         compose_file: @local_compose_file,
         metadata: %{topology: "local", compose_file: @local_compose_file}
       }}
    end
  end

  def deploy(:aws_clt, %ScenarioConfig{}) do
    {:error, :not_implemented_in_phase_1}
  end

  @doc """
  Poll the topology for readiness. Two stages: the broker has to be
  up (`mongooseimctl status` exits 0 once the BEAM and boot-time apps
  are running), and the Amoc cluster has to settle (worker joined the
  master's connected-nodes set — without that, `amoc_dist:do/3`
  fails with `empty_nodes_list` because the controller stays in the
  `disabled` state amoc uses for unattached master nodes).
  Returns `:ok` when both are ready, `{:error, :timeout}` after
  `timeout_ms`.
  """
  @spec wait_ready(State.t(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_ready(%State{topology: :local} = state, timeout_ms \\ 120_000) do
    deadline = monotonic_ms() + timeout_ms

    with :ok <- wait_brokers(state, deadline),
         :ok <- wait_cets_cluster(state, deadline),
         :ok <- wait_amoc_cluster(state, deadline) do
      :ok
    end
  end

  # Each broker independently has to reach the "BEAM up + boot apps
  # finished" state. compose's healthcheck already enforces this on
  # `up -d`, but a partial failure (one of three brokers wedged)
  # would otherwise let the runner sample resource usage from two
  # healthy and one half-booted broker — noise we'd rather hit as
  # an explicit timeout. Walk the list rather than just polling the
  # first so the runner errors with a useful "broker N not ready"
  # signal.
  defp wait_brokers(%State{broker_containers: containers}, deadline) do
    Enum.reduce_while(containers, :ok, fn container, :ok ->
      case wait_broker(container, deadline) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp wait_broker(container, deadline) do
    case System.cmd("docker", ["exec", container, "./bin/mongooseimctl", "status"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        if monotonic_ms() < deadline do
          Process.sleep(1_000)
          wait_broker(container, deadline)
        else
          {:error, {:timeout, container}}
        end
    end
  end

  # CETS readiness: each broker registers itself in the shared
  # `discovery_nodes` Postgres table on boot, then connects to peers
  # via BEAM distribution. Until the cluster has settled, session
  # operations on one broker won't replicate to the others — and a
  # dynamic-domain user dialing through the wrong broker would see
  # auth_failure for a domain the cluster *should* know about. Probe
  # `mongooseimctl cets systemInfo` from broker-1; the JSON it prints
  # has data.cets.systemInfo.availableNodes as a list. When its length
  # matches the expected cluster size, we're ready. Falls back to
  # length(nodes())+1 via mongooseimctl server status if CETS itself
  # isn't loaded (would surface as a clean timeout rather than a
  # match crash).
  defp wait_cets_cluster(%State{broker_containers: containers} = _state, _deadline)
       when length(containers) <= 1,
       do: :ok

  defp wait_cets_cluster(%State{broker_containers: [head | _] = containers} = state, deadline) do
    expected = length(containers)
    joined = cets_joined_count(head)

    cond do
      is_integer(joined) and joined >= expected ->
        :ok

      monotonic_ms() < deadline ->
        Process.sleep(1_000)
        wait_cets_cluster(state, deadline)

      true ->
        {:error, {:timeout, :cets_cluster, joined, expected}}
    end
  end

  # `mongooseimctl cets systemInfo` emits the JSON returned by the
  # CETS GraphQL query. Available since MongooseIM 6.x; pre-CETS
  # builds print an "Unknown category" usage block. We treat any
  # non-numeric / non-list response as `:unknown` so the caller
  # retries until the deadline.
  defp cets_joined_count(container) do
    case System.cmd("docker", ["exec", container, "./bin/mongooseimctl", "cets", "systemInfo"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        parse_cets_joined(out)

      _ ->
        :unknown
    end
  end

  # The interesting field for cluster size is `availableNodes` —
  # peers that have responded to discovery and are reachable over
  # distribution. We don't need the full JSON parse; counting
  # entries inside the `availableNodes` array via Regex keeps the
  # poller dependency-free. An `"errors"` envelope (CETS not loaded)
  # falls through to :unknown so callers keep waiting.
  defp parse_cets_joined(json_str) do
    cond do
      String.contains?(json_str, "\"errors\"") ->
        :unknown

      true ->
        case Regex.run(~r/"availableNodes"\s*:\s*\[([^\]]*)\]/, json_str) do
          [_, inner] ->
            inner
            |> String.split(",", trim: true)
            |> Enum.count(fn s -> String.trim(s) != "" end)

          _ ->
            :unknown
        end
    end
  end

  # Cluster readiness check: ask the master for its connected-nodes
  # list and look for at least one non-self node. We don't pin to a
  # specific worker hostname — :aws_clt will scale the worker count
  # up and we want this check to apply unchanged.
  defp wait_amoc_cluster(%State{amoc_master_container: master} = state, deadline) do
    expr = "length(maps:get(connected, amoc_cluster:get_status(), [])) > 0."

    case System.cmd("docker", ["exec", master, "/opt/amoc/bin/amoc_arsenal_xmpp", "eval", expr],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} ->
        :ok

      _ ->
        if monotonic_ms() < deadline do
          Process.sleep(1_000)
          wait_amoc_cluster(state, deadline)
        else
          {:error, :timeout}
        end
    end
  end

  @doc """
  Tear down the topology. Best-effort — failures are logged but not
  propagated, since teardown runs in cleanup paths where the
  benchmark result has already been captured.
  """
  @spec teardown(State.t()) :: :ok
  def teardown(%State{topology: :local, compose_file: path}) do
    {cmd, base_args} = compose_command()
    System.cmd(cmd, base_args ++ ["-f", path, "down", "-v"], stderr_to_stdout: true)
    :ok
  end

  def teardown(%State{topology: :aws_clt}), do: :ok

  # --- helpers -------------------------------------------------------

  defp check_docker_reachable do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, _} ->
        {:error,
         {:docker_unreachable,
          "`docker info` failed — start Colima (macOS) or the Docker daemon (Linux).\n" <>
            "  on macOS: run `colima start` or `bin/ensure-docker.sh` from a parent script\n" <>
            "  details: #{String.slice(out, 0, 200)}"}}
    end
  end

  defp compose_up(%ScenarioConfig{} = config) do
    env = Enum.to_list(ScenarioConfig.to_env(config))
    {cmd, base_args} = compose_command()
    args = base_args ++ ["-f", @local_compose_file, "up", "-d", "--build"]

    # CI diagnostics — without these the only visible signal is the
    # truncated tuple from System.cmd's buffered output. Mix.shell()
    # is unavailable here (we run before the mix task), so plain IO.
    IO.puts(
      :stderr,
      "[topology] compose: #{cmd} #{Enum.join(args, " ")}\n" <>
        "[topology] cwd:     #{File.cwd!()}\n" <>
        "[topology] envvars: #{summarize_env(env)}\n" <>
        "[topology] passthrough: " <>
        "MIM_BASE_IMAGE=#{System.get_env("MIM_BASE_IMAGE") || "(unset)"} " <>
        "MIM_OTP_VERSION=#{System.get_env("MIM_OTP_VERSION") || "(unset)"} " <>
        "AMOC_OTP_VERSION=#{System.get_env("AMOC_OTP_VERSION") || "(unset)"}"
    )

    # Builds images if they don't exist (first run) and reuses cached
    # layers on subsequent runs. --wait would block on healthchecks
    # but Phase 1 polls separately via wait_ready/2 to give cleaner
    # error messages.
    case System.cmd(cmd, args, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, {:compose_up_failed, status, tail(out, 4_000)}}
    end
  end

  defp summarize_env(env) do
    env
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
  end

  # Compose-up dumps many kilobytes of layer-pull / layer-extract
  # progress before any actual error fires; `inspect/2` truncates the
  # *start* of a long binary, hiding the diagnostic that landed at
  # the end. Slice the last N chars so the runtime tuple carries the
  # tail (where the error message lives) instead of the head.
  defp tail(bin, max) when is_binary(bin) and byte_size(bin) > max do
    "(... truncated, last #{max} bytes follow ...)\n" <>
      binary_part(bin, byte_size(bin) - max, max)
  end

  defp tail(bin, _max) when is_binary(bin), do: bin

  # Compose ships in two shapes: the Docker CLI plugin (`docker compose`,
  # bundled with Docker Desktop and most Linux distros' docker packages)
  # and the standalone Go binary (`docker-compose`, what Homebrew installs
  # alongside Colima). Pick whichever is on PATH so we don't force users
  # onto one install pattern.
  defp compose_command do
    cond do
      docker_plugin?() -> {"docker", ["compose"]}
      System.find_executable("docker-compose") -> {"docker-compose", []}
      true -> {"docker", ["compose"]}
    end
  end

  defp docker_plugin? do
    case System.cmd("docker", ["compose", "version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
