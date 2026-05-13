# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.BatchAdjust do
  @moduledoc """
  Rescale Benchee's per-batch statistics back to per-call units.

  OtpBenchmarks families that wrap each call in an inner-loop batch
  (e.g. `phash2` running 1000 hashes per Benchee invocation) need
  the resulting median / percentiles / std_dev / sample_size
  divided by the batch size so the published dashboard cell reads
  in per-call ns rather than per-batch ns.

  This module was duplicated for over a year between
  `lib/awfy/otp_benchmarks/runner.ex` (peer path) and
  `apps/awfy_target_runner/lib/awfy/target_runner.ex` (legacy bundle
  path) — same function, two byte-identical bodies, no test pinning
  the equivalence. PLAN/INFRA_REFACTOR.md § 2 collapses both via
  bundle-build codegen: the target runner's `lib/awfy/` gets a
  generated copy of this file at build time so the two compile
  units share one source of truth.

  Stddev rationale: Benchee reports σ over the batched sums, so
  `σ_per_batch ≈ σ_per_call √N`. Dividing by N yields
  `σ_per_call / √N` — the standard error of the per-call mean, which
  is exactly what a stability metric wants ("how much will the
  median move on re-run?"). Tighter than the raw per-sample σ.
  """

  @doc """
  Rescale every scenario's `:run_time_data.statistics` block by its
  batch size. `batched_inputs` is a map keyed by Benchee
  `:input_name` whose values are `{raw, batch_size}` tuples (the
  shape `Awfy.OtpBenchmarks.Family.scaled_inputs/1` produces). Inputs
  not in the map, or with batch=1, are left untouched.
  """
  @spec adjust(struct(), map()) :: struct()
  def adjust(%{scenarios: scenarios} = suite, batched_inputs) when is_map(batched_inputs) do
    scenarios =
      Enum.map(scenarios, fn s ->
        batch =
          case s.input_name && Map.get(batched_inputs, s.input_name) do
            {_raw, b} -> b
            _ -> 1
          end

        if batch <= 1 do
          s
        else
          adjust_scenario(s, batch)
        end
      end)

    %{suite | scenarios: scenarios}
  end

  defp adjust_scenario(s, batch) do
    rtd = s.run_time_data
    stats = rtd.statistics

    divide = fn
      nil -> nil
      v when is_number(v) -> v / batch
    end

    new_stats =
      stats
      |> Map.update(:median, nil, divide)
      |> Map.update(:average, nil, divide)
      |> Map.update(:std_dev, nil, divide)
      |> Map.update(:minimum, nil, divide)
      |> Map.update(:maximum, nil, divide)
      |> Map.update(:mode, nil, fn
        nil -> nil
        v when is_number(v) -> v / batch
        vs when is_list(vs) -> Enum.map(vs, &(&1 / batch))
      end)
      |> Map.update(:percentiles, %{}, fn p ->
        Map.new(p || %{}, fn {k, v} ->
          {k, v && v / batch}
        end)
      end)
      |> Map.update(:sample_size, 0, fn n ->
        (n || 0) * batch
      end)

    %{s | run_time_data: %{rtd | statistics: new_stats}}
  end
end
