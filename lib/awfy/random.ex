defmodule Awfy.Random do
  @moduledoc """
  Deterministic LCG matching SOM's Random class. Seed = 74755.

  Pure-functional: `next/1` returns `{value, new_seed}`.
  """

  @spec new() :: non_neg_integer()
  def new, do: 74755

  @spec next(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def next(seed) do
    new_seed = Bitwise.band(seed * 1309 + 13849, 65535)
    {new_seed, new_seed}
  end
end
