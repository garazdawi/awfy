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
  """

  alias Awfy.Xmpp.ScenarioConfig

  @local_compose_file Path.expand("../../../priv/topology/local.compose.yml", __DIR__)

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :topology,
      :broker_host,
      :broker_port,
      :amoc_master_container,
      :amoc_worker_container,
      :metadata
    ]
    defstruct @enforce_keys ++ [compose_file: nil]

    @type t :: %__MODULE__{
            topology: :local | :aws_clt,
            broker_host: String.t(),
            broker_port: pos_integer(),
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
         broker_host: "localhost",
         broker_port: 5222,
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

    with :ok <- wait_broker(deadline),
         :ok <- wait_amoc_cluster(state, deadline) do
      :ok
    end
  end

  defp wait_broker(deadline) do
    case System.cmd("docker", ["exec", "awfy-mongooseim", "./bin/mongooseimctl", "status"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        if monotonic_ms() < deadline do
          Process.sleep(1_000)
          wait_broker(deadline)
        else
          {:error, :timeout}
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

    # Builds images if they don't exist (first run) and reuses cached
    # layers on subsequent runs. --wait would block on healthchecks
    # but Phase 1 polls separately via wait_ready/2 to give cleaner
    # error messages.
    case System.cmd(
           cmd,
           base_args ++ ["-f", @local_compose_file, "up", "-d", "--build"],
           env: env,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, status} -> {:error, {:compose_up_failed, status, tail(out, 4_000)}}
    end
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
