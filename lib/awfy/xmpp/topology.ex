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
    @enforce_keys [:topology, :broker_host, :broker_port, :amoc_container, :metadata]
    defstruct @enforce_keys ++ [compose_file: nil]

    @type t :: %__MODULE__{
            topology: :local | :aws_clt,
            broker_host: String.t(),
            broker_port: pos_integer(),
            amoc_container: String.t(),
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
         amoc_container: "awfy-amoc",
         compose_file: @local_compose_file,
         metadata: %{topology: "local", compose_file: @local_compose_file}
       }}
    end
  end

  def deploy(:aws_clt, %ScenarioConfig{}) do
    {:error, :not_implemented_in_phase_1}
  end

  @doc """
  Poll the broker for readiness — `mongooseimctl status` exits 0
  only when the BEAM is up and the boot-time apps have started.
  Returns `:ok` when ready, `{:error, :timeout}` after `timeout_ms`.
  """
  @spec wait_ready(State.t(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_ready(%State{topology: :local}, timeout_ms \\ 60_000) do
    deadline = monotonic_ms() + timeout_ms
    wait_loop(deadline)
  end

  defp wait_loop(deadline) do
    case System.cmd("docker", ["exec", "awfy-mongooseim", "./bin/mongooseimctl", "status"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        if monotonic_ms() < deadline do
          Process.sleep(1_000)
          wait_loop(deadline)
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
    System.cmd("docker", ["compose", "-f", path, "down", "-v"],
      stderr_to_stdout: true
    )

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

    # `docker compose up -d --build` builds the images if they don't
    # exist (first run) and reuses cached layers on subsequent runs.
    # --wait would block on healthchecks but Phase 1 polls separately
    # via wait_ready/2 to give cleaner error messages.
    case System.cmd(
           "docker",
           ["compose", "-f", @local_compose_file, "up", "-d", "--build"],
           env: env,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, status} -> {:error, {:compose_up_failed, status, out}}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
