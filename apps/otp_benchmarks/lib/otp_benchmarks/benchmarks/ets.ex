# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Ets do
  @moduledoc """
  Single-scheduler ETS coverage drawn from `stdlib`'s
  `ets_SUITE`'s `throughput_benchmark`. We pick a focused subset
  rather than running its 100+ Cartesian configuration matrix —
  the upstream sweep is overkill for daily CI; the cuts below
  cover the failure modes that drive the BIF-dispatch and
  lock-strategy code paths:

    * `lookup_*`     — `:ets.lookup/2` with a fixed key, against
                       all four table types (set / ordered_set /
                       bag / duplicate_bag). Catches BIF-dispatch
                       and per-table-type read regressions.
    * `insert_*`     — `:ets.insert/2` with a fixed key, set /
                       ordered_set / bag. (`duplicate_bag` is
                       skipped: it would grow unboundedly across
                       Benchee's measurement window since each
                       insert appends a new copy.)
    * `mixed_*`      — alternating lookup + insert in one timed
                       call, set / ordered_set / bag. Same
                       duplicate_bag exclusion.
    * `bulk_insert`  — `:ets.insert/2` with a 1000-element list
                       (set). Bulk write path.
    * `bulk_select`  — `:ets.select/2` returning ~half the table
                       (set). Match-spec hot path.
    * `bulk_match`   — `:ets.match/2` returning every entry (set).
    * `update_counter` / `update_element` — atomic-update opcodes
                       the JIT specifically targets, set only.
    * `key_*`        — lookup on set across int / atom / tuple /
                       binary key types; different hash + compare
                       costs per key shape.

  Multi-scheduler concurrency (CA-tree path on `ordered_set` with
  `read_concurrency` / `write_concurrency`, scheduler counts 2 / N)
  is the natural follow-up — it needs spawning multiple measurer
  processes and aggregating, which is bigger than this commit's
  scope and tracked separately under `PLAN/EXTENDED_BENCH_PLAN.md`'s
  ETS section.

  The table is created `:public` so concurrent variants can share
  state without owner-process gymnastics; teardown cleans it up
  unconditionally.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "ets"

  @populate_size 1000

  def inputs do
    base_table_types = [:set, :ordered_set, :bag, :duplicate_bag]
    write_table_types = [:set, :ordered_set, :bag]

    lookup = for tt <- base_table_types, do: {"lookup_#{tt}", {:lookup, tt}}
    insert = for tt <- write_table_types, do: {"insert_#{tt}", {:insert, tt}}
    mixed = for tt <- write_table_types, do: {"mixed_#{tt}", {:mixed, tt}}

    bulk = [
      {"bulk_insert_1000", {:bulk_insert, :set}},
      {"bulk_select_half", {:bulk_select, :set}},
      {"bulk_match_all", {:bulk_match, :set}}
    ]

    update = [
      {"update_counter_set", {:update_counter, :set}},
      {"update_element_set", {:update_element, :set}}
    ]

    keys = for kt <- [:int, :atom, :tuple, :binary], do: {"key_#{kt}", {:key_lookup, kt}}

    Enum.into(lookup ++ insert ++ mixed ++ bulk ++ update ++ keys, %{})
  end

  def setup({:lookup, table_type}) do
    tab = create_table(table_type)
    populate(tab)
    {:lookup, tab}
  end

  def setup({:insert, table_type}) do
    tab = create_table(table_type)
    populate(tab)
    {:insert, tab}
  end

  def setup({:mixed, table_type}) do
    tab = create_table(table_type)
    populate(tab)
    {:mixed, tab}
  end

  def setup({:bulk_insert, table_type}) do
    tab = create_table(table_type)
    {:bulk_insert, tab, build_pairs(@populate_size)}
  end

  def setup({:bulk_select, table_type}) do
    tab = create_table(table_type)
    populate(tab)
    {:bulk_select, tab}
  end

  def setup({:bulk_match, table_type}) do
    tab = create_table(table_type)
    populate(tab)
    {:bulk_match, tab}
  end

  def setup({:update_counter, table_type}) do
    tab = create_table(table_type)
    :ets.insert(tab, {1, 0})
    {:update_counter, tab}
  end

  def setup({:update_element, table_type}) do
    tab = create_table(table_type)
    :ets.insert(tab, {1, "old"})
    {:update_element, tab}
  end

  def setup({:key_lookup, key_type}) do
    tab = create_table(:set)
    key = key_for(key_type)
    :ets.insert(tab, {key, "value"})
    {:key_lookup, tab, key}
  end

  def run({:lookup, tab}), do: :ets.lookup(tab, 500)
  def run({:insert, tab}), do: :ets.insert(tab, {1, "value"})

  def run({:mixed, tab}) do
    :ets.lookup(tab, 1)
    :ets.insert(tab, {1, "value"})
  end

  def run({:bulk_insert, tab, pairs}), do: :ets.insert(tab, pairs)

  def run({:bulk_select, tab}) do
    :ets.select(tab, [{{:"$1", :"$2"}, [{:>, :"$1", 500}], [:"$2"]}])
  end

  def run({:bulk_match, tab}), do: :ets.match(tab, {:"$1", :"$2"})

  def run({:update_counter, tab}), do: :ets.update_counter(tab, 1, 1)
  def run({:update_element, tab}), do: :ets.update_element(tab, 1, {2, "new"})

  def run({:key_lookup, tab, key}), do: :ets.lookup(tab, key)

  # First element of every state tuple is the op atom; the table
  # reference is at position 1 (zero-indexed). teardown peels it
  # unconditionally rather than pattern-matching every shape.
  def teardown(state) when is_tuple(state), do: :ets.delete(elem(state, 1))

  defp create_table(table_type), do: :ets.new(:awfy_ets, [table_type, :public])

  defp populate(tab) do
    Enum.each(1..@populate_size, fn k -> :ets.insert(tab, {k, "value_#{k}"}) end)
  end

  defp build_pairs(size), do: Enum.map(1..size, fn k -> {k, "value_#{k}"} end)

  defp key_for(:int), do: 42
  defp key_for(:atom), do: :a_typical_atom
  defp key_for(:tuple), do: {:tag, 42, "data"}
  defp key_for(:binary), do: <<"a binary key">>
end
