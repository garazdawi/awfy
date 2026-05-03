# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule Awfy.Benchmarks.Sieve do
  @moduledoc """
  Sieve of Eratosthenes — translated from upstream/benchmarks/Ruby/sieve.rb.

  Counts primes up to 5000 using a 5000-element flag array. Uses
  Erlang's `:array` module — the natural BEAM equivalent of Ruby's
  `Array.new`.
  """

  use Awfy.Benchmark

  @size 5000

  def name, do: "Sieve"

  def verify_result(result), do: result == 669

  def benchmark do
    flags = :array.new(@size, default: true)
    sieve(flags, @size)
  end

  defp sieve(flags, size), do: sieve_loop(2, size, flags, 0)

  defp sieve_loop(i, size, _flags, prime_count) when i > size, do: prime_count

  defp sieve_loop(i, size, flags, prime_count) do
    case :array.get(i - 1, flags) do
      true ->
        flags1 = mark(i + i, i, size, flags)
        sieve_loop(i + 1, size, flags1, prime_count + 1)

      false ->
        sieve_loop(i + 1, size, flags, prime_count)
    end
  end

  defp mark(k, _step, size, flags) when k > size, do: flags
  defp mark(k, step, size, flags), do: mark(k + step, step, size, :array.set(k - 1, false, flags))
end
