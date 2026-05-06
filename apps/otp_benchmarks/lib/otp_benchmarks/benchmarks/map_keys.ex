# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.MapKeys do
  @moduledoc """
  `:maps.keys/1` — proxy for the cost of walking every entry in a
  map and producing a list. Across the small-map → HAMT cutover
  this exercises two very different code paths: the flatmap
  variant just iterates the underlying tuple, the HAMT variant
  recursively walks the tree.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "map_keys"

  def inputs do
    %{
      "n5" => 5,
      "n32" => 32,
      "n100" => 100,
      "n1000" => 1000
    }
  end

  def setup(size), do: Map.new(1..size, &{&1, &1})

  def run(map), do: :maps.keys(map)
end
