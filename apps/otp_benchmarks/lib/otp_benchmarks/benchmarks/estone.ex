# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Estone do
  @moduledoc """
  estone-style microbenchmarks — wide-spectrum coverage of the
  BEAM's hot paths, modelled on `stdlib`'s `estone_SUITE`'s
  micros/0 entries. We don't try to faithfully reproduce upstream
  estone's iteration counts (those produce ~30 s of work on a
  *2002-era* machine; on modern hardware they're ~3 ms with very
  noisy stats — the plan's open question #4 about scaling). Each
  scenario here is one tight loop of a representative op; Benchee
  picks the iteration count to hit its `:time` budget.

  This commit covers the main categories upstream estone tracks;
  the remaining micros (timer, port I/O, links, run-queue, etc.)
  are deferred to follow-ups when the framework's behaviour is
  proven across this representative set:

    * `lists_sum`      — `:lists.sum/1` over a 1000-int list
    * `lists_foreach`  — `:lists.foreach/2` over the same
    * `pattern`        — five-clause function-head pattern match
    * `int_arith`      — sum + multiply over 1..100 ints
    * `float_arith`    — fold floats through arithmetic
    * `bif_dispatch`   — tight loop of `:erlang.abs/1` calls
    * `binary_build`   — iolist → binary roll-up
    * `ets_basic`      — insert + lookup pair on a `:set` table

  The composite ESTONES headline (per the plan's open question #1)
  isn't computed at this layer — the dashboard's geomean across
  the scenarios serves the same purpose, weighted equally.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "estone"

  def inputs do
    %{
      "lists_sum" => :lists_sum,
      "lists_foreach" => :lists_foreach,
      "pattern" => :pattern,
      "int_arith" => :int_arith,
      "float_arith" => :float_arith,
      "bif_dispatch" => :bif_dispatch,
      "binary_build" => :binary_build,
      "ets_basic" => :ets_basic
    }
  end

  def setup(:lists_sum), do: {:lists_sum, Enum.to_list(1..1000)}
  def setup(:lists_foreach), do: {:lists_foreach, Enum.to_list(1..1000)}

  def setup(:pattern) do
    {:pattern,
     [
       {:a, 1, "x"},
       {:b, 2, "y", :extra},
       {:c, 3, "z", :extra, "more"},
       {:d, 4},
       {:e}
     ]}
  end

  def setup(:int_arith), do: :int_arith
  def setup(:float_arith), do: :float_arith
  def setup(:bif_dispatch), do: {:bif_dispatch, Enum.to_list(1..100)}
  def setup(:binary_build), do: {:binary_build, Enum.map(1..100, fn _ -> "abc" end)}

  def setup(:ets_basic) do
    tab = :ets.new(:awfy_estone, [:set, :public])
    :ets.insert(tab, {1, "value"})
    {:ets_basic, tab}
  end

  def run({:lists_sum, list}), do: :lists.sum(list)
  def run({:lists_foreach, list}), do: :lists.foreach(fn _ -> :ok end, list)

  def run({:pattern, items}) do
    Enum.each(items, fn
      {:a, _, _} -> :a
      {:b, _, _, _} -> :b
      {:c, _, _, _, _} -> :c
      {:d, _} -> :d
      {:e} -> :e
    end)
  end

  def run(:int_arith) do
    Enum.reduce(1..100, 0, fn n, acc -> acc + n * 7 - 3 end)
  end

  def run(:float_arith) do
    Enum.reduce(1..100, 0.0, fn n, acc -> acc + n * 3.14 - 1.41 end)
  end

  def run({:bif_dispatch, list}) do
    Enum.each(list, fn n -> :erlang.abs(n) end)
  end

  def run({:binary_build, parts}), do: :erlang.iolist_to_binary(parts)

  def run({:ets_basic, tab}) do
    :ets.insert(tab, {1, "v"})
    :ets.lookup(tab, 1)
  end

  def teardown({:ets_basic, tab}), do: :ets.delete(tab)
  def teardown(_), do: :ok
end
