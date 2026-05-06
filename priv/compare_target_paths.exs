# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

# Parity-check engine driven by `bin/compare-target-paths.sh`.
# Reads two AWFY run directories (one from the legacy `-target`
# path, one from the new `-target-v2` bundle path) and compares
# per-benchmark medians. Acceptance thresholds per
# PLAN/TARGET_ELIXIR_RUNNER_PLAN.md decision #9.

legacy_dir = System.fetch_env!("AWFY_COMPARE_LEGACY")
bundle_dir = System.fetch_env!("AWFY_COMPARE_BUNDLE")

medians = fn dir ->
  Path.wildcard(Path.join(dir, "*.benchee"))
  |> Enum.into(%{}, fn path ->
    name = Path.basename(path, ".benchee")
    suite = path |> File.read!() |> :erlang.binary_to_term()

    by_scenario =
      Enum.into(suite.scenarios, %{}, fn s ->
        median = (s.run_time_data.statistics.median || 0) / 1.0
        {s.name, median}
      end)

    {name, by_scenario}
  end)
end

old = medians.(legacy_dir)
new = medians.(bundle_dir)

names =
  old
  |> Map.keys()
  |> MapSet.new()
  |> MapSet.union(new |> Map.keys() |> MapSet.new())

rows =
  for bench <- Enum.sort(names),
      old_scenarios = Map.get(old, bench, %{}),
      new_scenarios = Map.get(new, bench, %{}),
      scenario <- Enum.sort(Map.keys(old_scenarios)),
      Map.has_key?(new_scenarios, scenario) do
    o = Map.fetch!(old_scenarios, scenario)
    n = Map.fetch!(new_scenarios, scenario)
    delta = if o == 0, do: 0.0, else: (n - o) / o
    {bench <> "/" <> scenario, o, n, delta}
  end

IO.puts("benchmark/scenario                          old(ns)         new(ns)   Δ%")
IO.puts(String.duplicate("-", 80))

Enum.each(rows, fn {label, o, n, d} ->
  :io.format("~-46s ~12.0f ~12.0f ~+8.2f%~n", [label, o, n, d * 100])
end)

# `worst` short-circuits to 0.0 when there are no overlapping
# benchmarks — empty parity check is a no-op rather than a crash.
worst = rows |> Enum.map(fn {_l, _o, _n, d} -> abs(d) end) |> Enum.max(fn -> 0.0 end)

geomean =
  case Enum.map(rows, fn {_l, _o, _n, d} -> :math.log(1 + d) end) do
    [] -> 0.0
    deltas -> :math.exp(Enum.sum(deltas) / length(deltas)) - 1
  end

IO.puts("")
:io.format("aggregate geomean delta: ~+.2f%~n", [geomean * 100])
:io.format("worst absolute delta:    ~.2f%~n", [worst * 100])

cond do
  rows == [] ->
    IO.puts(:stderr, "WARN: no overlapping benchmarks between the two paths")
    exit({:shutdown, 0})

  abs(geomean) > 0.05 ->
    IO.puts(:stderr, "FAIL: geomean delta > 5%")
    exit({:shutdown, 1})

  worst > 0.15 ->
    IO.puts(:stderr, "FAIL: at least one benchmark drifted > 15%")
    exit({:shutdown, 1})

  true ->
    IO.puts("PASS: parity within tolerance")
end
