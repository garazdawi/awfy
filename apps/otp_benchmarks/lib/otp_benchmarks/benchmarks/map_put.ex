# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.MapPut do
  @moduledoc """
  `:maps.put/3` updating an existing key — the in-place / shared-
  spine path through the small-map and HAMT representations. The
  key is one already in the map, so the size doesn't change and we
  measure pure update cost; insertion-into-empty-slot is a
  separate code path tracked elsewhere when needed.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "map_put"

  def inputs do
    %{
      "n5" => 5,
      "n32" => 32,
      "n100" => 100,
      "n1000" => 1000
    }
  end

  def setup(size), do: Map.new(1..size, &{&1, &1})

  def run(map), do: :maps.put(1, 999, map)
end
