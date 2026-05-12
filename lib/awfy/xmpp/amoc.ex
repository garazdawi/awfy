# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Xmpp.Amoc do
  @moduledoc """
  Drive the Amoc load-gen via the release's `eval` command. Topology-
  agnostic in shape — for `:local` this runs `docker exec` against
  the local container; the same call shape works against a remote
  amoc-master in `:aws_clt` once Phase 2 supplies an exec-style
  helper there.
  """

  alias Awfy.Xmpp.{ScenarioConfig, Topology}

  @doc """
  Kick off the named scenario with the configured user count. Amoc
  reads the per-scenario `cfg(...)` values via `amoc_config_env`
  which we've populated from the compose env at container boot, so
  the only runtime arg is the user count.
  """
  @spec start_scenario(Topology.State.t(), ScenarioConfig.t()) :: :ok | {:error, term()}
  def start_scenario(%Topology.State{} = state, %ScenarioConfig{} = config) do
    expr = "amoc:do(#{config.scenario}, #{config.users}, [])."
    case exec_eval(state, expr) do
      {:ok, _output} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Sample the `messages_sent` counter once per second for
  `measurement_duration_s` seconds. Returns a list of per-second
  deltas (events delivered in that window) — `[non_neg_integer]`,
  one entry per second elapsed during measurement.

  Failures to read the counter become zeros so a transient `docker
  exec` flake doesn't crash the run; the run-level stability check
  (CV < 15 % across consecutive sweeps) will flag a topology that's
  silently dropping samples.
  """
  @spec sample_throughput(Topology.State.t(), ScenarioConfig.t()) :: [non_neg_integer()]
  def sample_throughput(%Topology.State{} = state, %ScenarioConfig{measurement_duration_s: secs}) do
    deadline = System.monotonic_time(:millisecond) + secs * 1_000
    prev = read_counter(state)
    sample_loop(state, prev, deadline, [])
  end

  defp sample_loop(state, prev, deadline, acc) do
    Process.sleep(1_000)
    now = read_counter(state)
    delta = max(0, now - prev)
    acc2 = [delta | acc]

    if System.monotonic_time(:millisecond) >= deadline do
      Enum.reverse(acc2)
    else
      sample_loop(state, now, deadline, acc2)
    end
  end

  defp read_counter(%Topology.State{} = state) do
    # `amoc_metrics:get_counter_value/1` returns the current counter
    # value as an integer (or undefined if the counter wasn't init'd
    # — happens for the first second or two while the scenario
    # boots).
    expr = "amoc_metrics:get_counter_value(messages_sent)."

    with {:ok, out} <- exec_eval(state, expr),
         {n, _} <- Integer.parse(String.trim(out)) do
      n
    else
      _ -> 0
    end
  end

  defp exec_eval(%Topology.State{topology: :local, amoc_container: container}, expr) do
    args = ["exec", container, "/opt/amoc/bin/amoc_arsenal_xmpp", "eval", expr]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:eval_failed, status, expr, out}}
    end
  end

  defp exec_eval(%Topology.State{topology: :aws_clt}, _expr) do
    # Phase 2 will wire this to `erl -remsh` or an HTTP API against
    # the amoc-master node. Same return shape as :local so the
    # caller doesn't branch.
    {:error, :not_implemented_in_phase_1}
  end
end
