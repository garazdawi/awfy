# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.MapMerge do
  @moduledoc """
  `:maps.merge/2` over two disjoint maps — exercises the bulk-copy
  path through the small-map / HAMT machinery. Inputs span:

    * symmetric small (5 + 5) → flatmap merge
    * symmetric at boundary (32 + 32) → HAMT merge
    * symmetric large (1000 + 1000) → sustained HAMT
    * asymmetric (5 + 1000) → small-into-large skew, which
      historically picks a different code path than the symmetric
      case (single insert per small-side entry vs full bulk copy).

  Disjoint key ranges so the merge does the full work rather than
  short-circuiting on overlapping keys.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "map_merge"

  def inputs do
    %{
      "n5_n5" => {5, 5},
      "n32_n32" => {32, 32},
      "n5_n1000" => {5, 1000},
      "n1000_n1000" => {1000, 1000}
    }
  end

  def setup({s1, s2}) do
    m1 = Map.new(1..s1, &{&1, &1})
    m2 = Map.new((s1 + 1)..(s1 + s2), &{&1, &1})
    {m1, m2}
  end

  def run({m1, m2}), do: :maps.merge(m1, m2)
end
