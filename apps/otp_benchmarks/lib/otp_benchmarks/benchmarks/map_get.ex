# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.MapGet do
  @moduledoc """
  `:maps.get/2` against integer keys in maps spanning the small-map
  → HAMT cutover. Sizes < 32 keys pay a linear scan over the
  flatmap representation; sizes ≥ 32 pay a HAMT lookup with
  allocator overhead. The looked-up key is fixed at `1` so the
  per-call work is constant within a scenario.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "map_get"

  def inputs do
    %{
      "n5" => 5,
      "n32" => 32,
      "n100" => 100,
      "n1000" => 1000
    }
  end

  def setup(size), do: Map.new(1..size, &{&1, &1})

  def run(map), do: :maps.get(1, map)
end
