# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.MetricSource do
  @moduledoc """
  Behaviour every per-second metric sampler implements.

  Today's only implementer is `Awfy.Xmpp.DockerStats` (cluster-
  aggregate CPU% + mem MB via `docker stats --no-stream`).
  PLAN/MONGOOSEIM_BENCH_PLAN.md § Phase 4 will add a Prometheus
  endpoint scraper — same contract, different transport — and
  PLAN/INFRA_REFACTOR.md § 5 documents the migration shape.

  ## Contract

  Each implementer carries its own opaque source descriptor (a list
  of docker container names, an HTTP URL, an SDK client, …).
  `sample_until/2` blocks until the monotonic-ms `deadline` passes,
  returning *parallel sample lists*: one entry per per-second
  sampling window, in collection order, so the dashboard can
  reconstruct the time series.

  Sources should:
    * Aggregate across cluster members (sum CPU% / mem MB across
      brokers in a multi-broker topology). The dashboard plots one
      number per second; gathering per-member values then summing
      preserves the "how much resource does the cluster need" trend
      signal.
    * Tolerate single-sample read failures by emitting a 0.0 / 0
      placeholder rather than crashing the whole run. A transient
      `docker stats` flake shouldn't end a 10-minute steady-state
      window.

  ## Sample shape

  The map's keys are atom-tagged so a source can declare which
  signals it produces and the runner can match them up to the
  appropriate Benchee scenarios:

      %{
        cpu_pct: [float()],   # per-second CPU% across cluster
        mem_mb:  [float()],   # per-second resident memory MB
        throughput: [number()] | nil   # event-rate, if known
      }

  Application-bench topologies (XMPP today, network later) provide
  cpu+mem from the broker side and throughput from the load-gen
  side; both end up in the same map for `Awfy.AppBench.Result.build_multi/2`.
  """

  @typedoc "Opaque per-source descriptor passed back to sample_until/2."
  @type t :: term()

  @typedoc "Sample shape one source returns. Throughput may be nil for cpu-only sources."
  @type samples :: %{
          cpu_pct: [float()],
          mem_mb: [float()],
          throughput: [number()] | nil
        }

  @doc """
  Sample the source once per second until the monotonic-ms
  `deadline` passes. Returns parallel sample lists. Single-sample
  failures should become a 0.0 placeholder; total source failure
  raises (so the runner can `try/after` the teardown).
  """
  @callback sample_until(source :: t(), deadline_ms :: integer()) :: samples()

  @doc """
  Return the list of metric atoms this source actually emits.
  Today's atoms: `:cpu_pct`, `:mem_mb`, `:throughput`. Future
  sources (BEAM-level via prometheus) extend this with finer-
  grained variants — see PLAN/MONGOOSEIM_BENCH_PLAN.md § Phase 4.
  """
  @callback supported_metrics(source :: t()) :: [atom()]
end
