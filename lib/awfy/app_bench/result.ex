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
    job_name = Keyword.get(opts, :job_name, scenario_name)
    input_name = Keyword.get(opts, :input, nil)

    periods_ns = Enum.map(samples, &throughput_to_period_ns/1)
    stats = compute_statistics(periods_ns)

    scenario = %{
      __struct__: Benchee.Scenario,
      name: scenario_name,
      job_name: job_name,
      input_name: input_name,
      input: input_name,
      tag: nil,
      function: nil,
      before_each: nil,
      after_each: nil,
      before_scenario: nil,
      after_scenario: nil,
      run_time_data: %{
        __struct__: Benchee.CollectionData,
        statistics: stats,
        samples: periods_ns
      },
      memory_usage_data: %{
        __struct__: Benchee.CollectionData,
        statistics: empty_statistics(),
        samples: []
      },
      reductions_data: %{
        __struct__: Benchee.CollectionData,
        statistics: empty_statistics(),
        samples: []
      }
    }

    %{
      __struct__: Benchee.Suite,
      configuration: %{__struct__: Benchee.Configuration, time: 0, warmup: 0},
      scenarios: [scenario],
      system: metadata,
      benchmarks: nil
    }
  end

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

      %{
        __struct__: Benchee.Statistics,
        average: mean,
        ips: nil,
        std_dev: stddev(nums, mean),
        std_dev_ratio: nil,
        std_dev_ips: nil,
        median: percentile(sorted, 0.5),
        percentiles: %{
          25 => percentile(sorted, 0.25),
          50 => percentile(sorted, 0.5),
          75 => percentile(sorted, 0.75),
          99 => percentile(sorted, 0.99)
        },
        mode: nil,
        minimum: List.first(sorted),
        maximum: List.last(sorted),
        sample_size: n,
        relative_more: nil,
        relative_less: nil,
        absolute_difference: nil
      }
    end
  end

  defp empty_statistics do
    %{
      __struct__: Benchee.Statistics,
      average: nil,
      ips: nil,
      std_dev: nil,
      std_dev_ratio: nil,
      std_dev_ips: nil,
      median: nil,
      percentiles: %{},
      mode: nil,
      minimum: nil,
      maximum: nil,
      sample_size: 0,
      relative_more: nil,
      relative_less: nil,
      absolute_difference: nil
    }
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
