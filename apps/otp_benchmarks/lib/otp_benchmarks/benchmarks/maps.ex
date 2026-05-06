# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Maps do
  @moduledoc """
  Map operations across the small-map → HAMT representation
  cutover (32 keys in modern OTP). All five core ops live in one
  family so the dashboard renders them on a single per-bench page;
  inputs are tagged `<op>_<size>` so the page's input checkboxes
  let you focus on one op while leaving the others on the same
  chart.

    * `get_*`    — `:maps.get(1, map)` against an existing key.
    * `put_*`    — `:maps.put(1, 999, map)` updating an existing
                   key (no resize, pure update path).
    * `new_*`    — `Map.new/1` from a `[{k,v}, ...]` list (bulk
                   construction, allocates fresh map per call).
    * `merge_*`  — `:maps.merge(m1, m2)` over disjoint maps;
                   covers symmetric small/medium/large + an
                   asymmetric 5+1000 case for the small-into-large
                   skew code path.
    * `keys_*`   — `:maps.keys/1` as proxy for whole-map traversal.

  Sizes target 5 / 32 / 100 / 1000 — straddling the cutover with
  one input on either side, plus a sustained-HAMT case at 1000.
  10 000 was on the original plan but skipped here: at default
  Benchee `:time` budgets it produces fewer samples than tighter
  inputs while not surfacing different code paths than 1000.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "maps"

  @sizes [5, 32, 100, 1000]
  @merge_pairs [{5, 5}, {32, 32}, {5, 1000}, {1000, 1000}]

  def inputs do
    point_size_inputs = for op <- [:get, :put, :new, :keys], size <- @sizes do
      {"#{op}_n#{size}", {op, size}}
    end

    merge_inputs = for {s1, s2} <- @merge_pairs do
      {"merge_n#{s1}_n#{s2}", {:merge, {s1, s2}}}
    end

    Enum.into(point_size_inputs ++ merge_inputs, %{})
  end

  # Per-scenario setup: build whatever shape `run/1` needs ready
  # so the timed loop is op-only. Each branch returns a tagged
  # tuple that `run/1` pattern-matches on.
  def setup({:get, size}), do: {:get, build_map(size)}
  def setup({:put, size}), do: {:put, build_map(size)}
  def setup({:new, size}), do: {:new, build_pairs(size)}
  def setup({:keys, size}), do: {:keys, build_map(size)}

  def setup({:merge, {s1, s2}}) do
    m1 = build_map(s1)
    m2 = Map.new((s1 + 1)..(s1 + s2), &{&1, &1})
    {:merge, m1, m2}
  end

  def run({:get, map}), do: :maps.get(1, map)
  def run({:put, map}), do: :maps.put(1, 999, map)
  def run({:new, pairs}), do: Map.new(pairs)
  def run({:keys, map}), do: :maps.keys(map)
  def run({:merge, m1, m2}), do: :maps.merge(m1, m2)

  defp build_map(size), do: Map.new(1..size, &{&1, &1})
  defp build_pairs(size), do: Enum.map(1..size, fn k -> {k, k} end)
end
