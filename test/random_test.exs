# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule AwfyTest.Random do
  @moduledoc """
  Compares Erlang and Elixir Random ports against the SOM/Ruby reference.

  The first 10 values produced by SOM's Random with seed 74755 are well
  known and identical across all upstream AWFY ports. Both BEAM ports
  must produce them.
  """

  use ExUnit.Case, async: true

  # First 10 values from a fresh Random instance, computed by hand from
  # the LCG: seed_{i+1} = (seed_i * 1309 + 13849) & 0xFFFF, seed_0 = 74755.
  # We ran the Ruby reference once to capture these.
  @reference [22896, 34761, 34014, 39231, 52540, 41445, 1546, 5947, 65224, 64193]

  test "Erlang awfy_random matches the reference" do
    {values, _} =
      Enum.reduce(1..10, {[], :awfy_random.new()}, fn _, {acc, seed} ->
        {v, new_seed} = :awfy_random.next(seed)
        {[v | acc], new_seed}
      end)

    assert Enum.reverse(values) == @reference
  end

  test "Elixir Awfy.Random matches the reference" do
    {values, _} =
      Enum.reduce(1..10, {[], Awfy.Random.new()}, fn _, {acc, seed} ->
        {v, new_seed} = Awfy.Random.next(seed)
        {[v | acc], new_seed}
      end)

    assert Enum.reverse(values) == @reference
  end
end
