# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule Awfy.Benchmarks.Queens do
  @moduledoc """
  Eight Queens — translated from upstream/benchmarks/Ruby/queens.rb.

  Solves the 8-queens problem 10 times. Returns true if all 10 runs
  find a valid placement. Boolean arrays are 8 or 16 elements, so we
  use tuples + put_elem (cheap at this size).
  """

  use Awfy.Benchmark

  defstruct [:free_rows, :free_maxs, :free_mins, :queen_rows]

  def name, do: "Queens"

  def verify_result(result), do: result

  def benchmark, do: run(10, true)

  defp run(0, acc), do: acc
  defp run(n, false), do: run(n - 1, false)
  defp run(n, true), do: run(n - 1, queens())

  defp queens do
    state = %__MODULE__{
      free_rows: Tuple.duplicate(true, 8),
      free_maxs: Tuple.duplicate(true, 16),
      free_mins: Tuple.duplicate(true, 16),
      queen_rows: Tuple.duplicate(-1, 8)
    }

    {result, _state1} = place_queen(0, state)
    result
  end

  defp place_queen(c, state), do: place_queen_row(0, c, state)

  defp place_queen_row(8, _c, state), do: {false, state}

  defp place_queen_row(r, c, state) do
    if get_row_column(r, c, state) do
      state1 = set_queen_row(r, c, state)
      state2 = set_row_column(r, c, false, state1)

      cond do
        c == 7 ->
          {true, state2}

        true ->
          case place_queen(c + 1, state2) do
            {true, state3} ->
              {true, state3}

            {false, state3} ->
              state4 = set_row_column(r, c, true, state3)
              place_queen_row(r + 1, c, state4)
          end
      end
    else
      place_queen_row(r + 1, c, state)
    end
  end

  defp get_row_column(r, c, %{free_rows: fr, free_maxs: fmx, free_mins: fmn}) do
    elem(fr, r) and elem(fmx, c + r) and elem(fmn, c - r + 7)
  end

  defp set_row_column(r, c, v, %{free_rows: fr, free_maxs: fmx, free_mins: fmn} = state) do
    %{
      state
      | free_rows: put_elem(fr, r, v),
        free_maxs: put_elem(fmx, c + r, v),
        free_mins: put_elem(fmn, c - r + 7, v)
    }
  end

  defp set_queen_row(r, c, %{queen_rows: qr} = state) do
    %{state | queen_rows: put_elem(qr, r, c)}
  end
end
