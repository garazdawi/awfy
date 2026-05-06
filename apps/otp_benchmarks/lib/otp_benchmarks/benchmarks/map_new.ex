# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.MapNew do
  @moduledoc """
  `Map.new/1` from a `[{key, value}, ...]` list — bulk construction.
  Allocates a fresh map per call, so per-call cost grows with size
  (small-map array build below 32, HAMT bucket build above).

  The setup hook builds the input list once per scenario. The
  timed loop measures only the map-build itself, not list
  construction.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "map_new"

  def inputs do
    %{
      "n5" => 5,
      "n32" => 32,
      "n100" => 100,
      "n1000" => 1000
    }
  end

  def setup(size), do: Enum.map(1..size, fn k -> {k, k} end)

  def run(pairs), do: Map.new(pairs)
end
