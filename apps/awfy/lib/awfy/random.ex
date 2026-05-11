# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule Awfy.Random do
  @moduledoc """
  Deterministic LCG matching SOM's Random class. Seed = 74755.

  Pure-functional: `next/1` returns `{value, new_seed}`.
  """

  @spec new() :: non_neg_integer()
  def new, do: 74755

  @spec next(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def next(seed) do
    new_seed = :erlang.band(seed * 1309 + 13849, 65535)
    {new_seed, new_seed}
  end
end
