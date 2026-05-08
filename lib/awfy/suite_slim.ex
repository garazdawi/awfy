# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.SuiteSlim do
  @moduledoc """
  Strip raw `samples` lists from a `%Benchee.Suite{}` before saving.

  Benchee's `:save` keeps every per-iteration time sample on the
  suite struct. For a 5-second budget at sub-microsecond iterations
  that runs into millions of integers per scenario; we've seen one
  family's `.benchee` blow past 60 MB. The dashboard
  (`Awfy.Compare.Data` + `priv/compare_target_paths.exs`) only ever
  reads `scenario.run_time_data.statistics`, so the samples are
  pure ballast — they cost disk on gh-pages and bandwidth on the
  publish-step `git push`, which has stalled an hour at a time on
  ~2.8 GB of artifacts.

  Slimming preserves the scalar `%Benchee.Statistics{}` block
  (median, mean, std_dev, sample_size, percentiles, …) and zeroes
  the per-iteration sample lists in three places:

    * `samples` on each `%Benchee.CollectionData{}` (run_time,
      memory_usage, reductions)
    * `outliers` on each `%Benchee.Statistics{}` — Benchee keeps
      the full list of outlier values when outlier exclusion runs,
      and that list is the dominant size for sub-µs benchmarks
      (one ETS scenario shipped 3.6 MB of outliers vs ~16 KB of
      everything else combined).

  Same logic is duplicated in
  `apps/awfy_target_runner/lib/awfy/target_runner.ex` because the
  cross-OTP bundle ships without this module — kept intentionally
  small so the duplicate stays trivial to keep in sync.
  """

  @doc """
  Return the suite with `.samples` cleared on every scenario's
  collection-data fields. Statistics + scenario metadata untouched.
  """
  @spec slim(%Benchee.Suite{}) :: %Benchee.Suite{}
  def slim(%Benchee.Suite{scenarios: scenarios} = suite) do
    %{suite | scenarios: Enum.map(scenarios, &slim_scenario/1)}
  end

  defp slim_scenario(%Benchee.Scenario{} = s) do
    %{
      s
      | run_time_data: clear_samples(s.run_time_data),
        memory_usage_data: clear_samples(s.memory_usage_data),
        reductions_data: clear_samples(s.reductions_data)
    }
  end

  defp clear_samples(%Benchee.CollectionData{statistics: stats} = cd) do
    %{cd | samples: [], statistics: clear_outliers(stats)}
  end

  defp clear_samples(other), do: other

  defp clear_outliers(%Benchee.Statistics{} = stats), do: %{stats | outliers: []}
  defp clear_outliers(other), do: other
end
