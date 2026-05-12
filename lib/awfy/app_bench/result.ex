# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.AppBench.Result do
  @moduledoc """
  Maps throughput-over-time samples from an application-level
  benchmark (one sample per measurement window — typically per-second
  buckets) into the `%Benchee.Suite{}` shape that
  `Awfy.Compare.Data.load/2` understands.

  Generic on purpose — used by the XMPP-bench path
  (`lib/awfy/xmpp/`) and (when implemented) the network-bench path
  (`lib/awfy/network/`). Doesn't know anything about XMPP or
  network namespaces; just "here are N samples of period-per-event
  in nanoseconds, here's the scenario name and metadata, produce a
  Benchee.Suite I can write_term to a .benchee file."

  ## Inverted units

  Application benchmarks report throughput (events/sec or msg/sec)
  but the existing dashboard's "lower = faster" convention assumes
  the row stores a *period*. We invert at the boundary: the sample
  stream comes in as throughputs, we store `period_ns = 10^9 /
  throughput` per sample, and `median / percentiles[…]` are
  computed over that period series. Throughput is recoverable for
  display as `1_000_000_000 / median`.
  """

  @doc """
  Build a `%Benchee.Suite{}` from a list of throughput samples (one
  per measurement window, in events/sec) and a scenario descriptor.

  `samples` may be empty — produces a degenerate suite with `nil`
  statistics that the dashboard renders as a missing row rather
  than crashing the compare flow.
  """
  @spec build([number()], String.t(), keyword()) :: struct()
  def build(samples, scenario_name, opts \\ []) when is_list(samples) and is_binary(scenario_name) do
    metadata = Keyword.get(opts, :metadata, %{})
    build_multi([{scenario_name, samples, opts}], metadata: metadata)
  end

  @doc """
  Build a `%Benchee.Suite{}` containing multiple scenarios from a list
  of `{name, samples, opts}` tuples. Used by the XMPP runner so a
  single .benchee file carries the throughput, CPU%, and memory
  series from one run as separate Benchee scenarios (so the dashboard
  can plot them side-by-side and a stability check can flag any one
  of them).

  Each per-scenario `opts` keyword list may set:
    * `:unit` — `:throughput_per_s` (default; inverts to period-ns so
      higher rate sorts as lower-=-better) or `:lower_better_raw`
      (CPU%, mem MB, anything already on a "lower=better" scale —
      stored as-is, no inversion).
    * `:job_name` — overrides the per-scenario job label.
    * `:input` — fills `input_name` for OtpBenchmarks-style multi-
      input runs; unused on Phase 1 :local but kept for parity.

  Top-level `opts`:
    * `:metadata` — populates the suite's `system` map; the runner
      drops topology metadata + per-scenario timing knobs in here.
  """
  @spec build_multi([{String.t(), [number()], keyword()}], keyword()) :: struct()
  def build_multi(scenarios, opts \\ []) when is_list(scenarios) do
    metadata = Keyword.get(opts, :metadata, %{})

    benchee_scenarios = Enum.map(scenarios, &build_scenario/1)

    struct(Benchee.Suite, %{
      configuration: struct(Benchee.Configuration, %{time: 0, warmup: 0}),
      scenarios: benchee_scenarios,
      system: metadata
    })
  end

  defp build_scenario({name, samples, opts}) do
    unit = Keyword.get(opts, :unit, :throughput_per_s)
    job_name = Keyword.get(opts, :job_name, name)
    input_name = Keyword.get(opts, :input, nil)

    transformed = transform(samples, unit)
    stats = compute_statistics(transformed)

    # struct/2 fills in every Benchee.Scenario / Benchee.CollectionData
    # / Benchee.Statistics key with its declared default — important
    # because SuiteSlim.slim/1 pattern-matches strictly on those
    # structs and would KeyError on a hand-rolled map that omits any
    # field (outliers/, inputs/, ...).
    struct(Benchee.Scenario, %{
      name: name,
      job_name: job_name,
      input_name: input_name,
      input: input_name,
      run_time_data:
        struct(Benchee.CollectionData, %{statistics: stats, samples: transformed}),
      memory_usage_data:
        struct(Benchee.CollectionData, %{statistics: empty_statistics(), samples: []}),
      reductions_data:
        struct(Benchee.CollectionData, %{statistics: empty_statistics(), samples: []})
    })
  end

  defp transform(samples, :throughput_per_s),
    do: Enum.map(samples, &throughput_to_period_ns/1)

  defp transform(samples, :lower_better_raw),
    do: Enum.filter(samples, &is_number/1)

  defp throughput_to_period_ns(0), do: nil
  defp throughput_to_period_ns(thr) when is_number(thr) and thr > 0, do: 1_000_000_000 / thr
  defp throughput_to_period_ns(_), do: nil

  defp compute_statistics([]), do: empty_statistics()

  defp compute_statistics(samples) do
    nums = Enum.filter(samples, &is_number/1)

    if nums == [] do
      empty_statistics()
    else
      sorted = Enum.sort(nums)
      n = length(sorted)
      sum = Enum.sum(sorted)
      mean = sum / n

      struct(Benchee.Statistics, %{
        average: mean,
        std_dev: stddev(nums, mean),
        median: percentile(sorted, 0.5),
        percentiles: %{
          25 => percentile(sorted, 0.25),
          50 => percentile(sorted, 0.5),
          75 => percentile(sorted, 0.75),
          99 => percentile(sorted, 0.99)
        },
        minimum: List.first(sorted),
        maximum: List.last(sorted),
        sample_size: n,
        outliers: []
      })
    end
  end

  defp empty_statistics do
    struct(Benchee.Statistics, %{percentiles: %{}, sample_size: 0, outliers: []})
  end

  defp percentile([only], _), do: only

  defp percentile(sorted, p) when is_list(sorted) and is_number(p) do
    # Nearest-rank interpolation — matches what Benchee does for
    # the canonical 25/50/75/99 keys on small-N data.
    n = length(sorted)
    idx = max(0, min(n - 1, trunc(p * (n - 1) + 0.5)))
    Enum.at(sorted, idx)
  end

  defp stddev(nums, mean) do
    variance =
      nums
      |> Enum.map(fn x -> (x - mean) * (x - mean) end)
      |> Enum.sum()
      |> Kernel./(length(nums))

    :math.sqrt(variance)
  end
end
