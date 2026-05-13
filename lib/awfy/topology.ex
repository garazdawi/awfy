# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Topology do
  @moduledoc """
  Behaviour every application-bench topology implements:
  deploy → wait_ready → metric_sources → teardown.

  Today's only implementer is `Awfy.Xmpp.Topology` (the 3-broker
  MongooseIM CETS cluster, in `:local` or `:aws_clt` flavour).
  Phase 2 of `PLAN/NETWORK_BENCH_PLAN_TIER1.md` will add
  `Awfy.Network.Topology`; Phase 4 of
  `PLAN/MONGOOSEIM_BENCH_PLAN.md` swaps `Awfy.Xmpp.DockerStats`
  (the only `Awfy.MetricSource` impl) for a Prometheus scrape. The
  behaviour exists so those substitutions are mechanical rather
  than a fresh interface-design pass each time.

  PLAN/INFRA_REFACTOR.md § 5.

  ## Lifecycle

  Each measure task drives a topology through four callbacks:

      {:ok, state} = Topology.deploy(MyTopology, config)
      try do
        :ok = Topology.wait_ready(MyTopology, state, 120_000)
        sources = Topology.metric_sources(MyTopology, state)
        # ... run scenario, sample sources ...
      after
        Topology.teardown(MyTopology, state)
      end

  Teardown is best-effort and runs in a cleanup path — partial
  failures during deploy/sample shouldn't leave the host with a
  half-built compose project or live EC2 instances.
  """

  @typedoc "Opaque per-implementation state returned by `c:deploy/1`."
  @type state :: term()

  @doc """
  Bring the topology up. Receives a scenario-specific config map
  (user counts, message rates, …) and returns the state handle
  every other callback will receive.
  """
  @callback deploy(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc """
  Poll the topology until every component is ready to serve load.
  Implementers should return `{:error, {:timeout, ...}}` rather
  than crashing — partial cluster failures should surface as
  measurement skips, not workflow aborts.
  """
  @callback wait_ready(state(), timeout_ms :: pos_integer()) :: :ok | {:error, term()}

  @doc """
  Return the list of metric sources this topology exposes. Each
  source is something the measure task can pass to
  `Awfy.MetricSource.sample_until/2`.
  """
  @callback metric_sources(state()) :: [Awfy.MetricSource.t()]

  @doc """
  Bring the topology down. Best-effort — failures during teardown
  are logged but not raised, since teardown runs in a cleanup path
  where the measurement result has already been captured.
  """
  @callback teardown(state()) :: :ok

  # --- Convenience wrappers ---------------------------------------

  @spec deploy(module(), map()) :: {:ok, state()} | {:error, term()}
  def deploy(module, config), do: module.deploy(config)

  @spec wait_ready(module(), state(), pos_integer()) :: :ok | {:error, term()}
  def wait_ready(module, state, timeout_ms), do: module.wait_ready(state, timeout_ms)

  @spec metric_sources(module(), state()) :: [Awfy.MetricSource.t()]
  def metric_sources(module, state), do: module.metric_sources(state)

  @spec teardown(module(), state()) :: :ok
  def teardown(module, state), do: module.teardown(state)
end
