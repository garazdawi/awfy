# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule Awfy.Benchmarks.Json do
  @moduledoc """
  Json — translated from upstream/benchmarks/Ruby/json.rb.

  Hand-written JSON parser plus a polymorphic JsonValue hierarchy.
  Doesn't depend on SOM Dictionary — uses its own HashIndexTable
  (32-slot integer table indexed by name-length hash). The benchmark
  parses a fixed ~25 KB string; verify_result/1 checks the resulting
  JsonObject contains a "head" object and an "operations" array of
  size 156.

  JsonValues are tagged tuples — preserves polymorphic dispatch via
  pattern matching without an actual class hierarchy.
  """

  use Awfy.Benchmark

  alias Awfy.Som.Vector

  def name, do: "Json"

  def verify_result(result) do
    case result do
      {:jobject, _, _, _} ->
        head = jobject_get(result, "head")
        ops = jobject_get(result, "operations")
        match?({:jobject, _, _, _}, head) and match?({:jarray, _}, ops) and jarray_size(ops) == 156

      _ ->
        false
    end
  end

  def benchmark do
    bin = test_input()
    parse(bin)
  end

  defp test_input do
    case :persistent_term.get({__MODULE__, :test_input}, nil) do
      nil ->
        path = Path.join(:code.priv_dir(:awfy), "rap_benchmark.json")
        {:ok, bin} = File.read(path)
        :persistent_term.put({__MODULE__, :test_input}, bin)
        bin

      bin ->
        bin
    end
  end

  # ---------- Polymorphic JsonValue (tagged tuples) ----------
  # {:jobject, names_vec, values_vec, hash_table}
  # {:jarray, values_vec}
  # {:jstring, bin}
  # {:jnumber, bin}
  # {:jliteral, :null | true | false}

  defp jarray_size({:jarray, v}), do: Vector.size(v)

  defp jobject_get({:jobject, names, values, table}, name) do
    case jht_get(table, name) do
      -1 ->
        nil

      idx ->
        if Vector.at(names, idx) === name do
          Vector.at(values, idx)
        else
          raise "not_implemented"
        end
    end
  end

  defp jobject_new, do: {:jobject, Vector.new(), Vector.new(), jht_new()}

  defp jobject_add({:jobject, names, values, table}, name, value) do
    names1 = Vector.append(names, name)
    values1 = Vector.append(values, value)
    table1 = jht_add(table, name, Vector.size(names))
    {:jobject, names1, values1, table1}
  end

  defp jarray_new, do: {:jarray, Vector.new()}

  defp jarray_add({:jarray, v}, value), do: {:jarray, Vector.append(v, value)}

  # ---------- HashIndexTable (32 slots) ----------
  @ht_size 32

  defp jht_new, do: Tuple.duplicate(0, @ht_size)

  defp jht_add(table, name, index) do
    slot = jht_slot(name)

    val =
      if index < 0xFF do
        Bitwise.band(index + 1, 0xFF)
      else
        0
      end

    put_elem(table, slot, val)
  end

  defp jht_get(table, name) do
    slot = jht_slot(name)
    Bitwise.band(elem(table, slot), 0xFF) - 1
  end

  defp jht_slot(name), do: Bitwise.band(byte_size(name) * 1_402_589, @ht_size - 1)

  # ---------- Parser ----------

  defmodule P do
    defstruct input: nil,
              index: -1,
              current: :eof,
              capture_start: -1,
              capture_buffer: <<>>
  end

  defp parse(bin) do
    p0 = %P{input: bin}
    p1 = read(p0)
    p2 = skip_whitespace(p1)
    {result, p3} = read_value(p2)
    p4 = skip_whitespace(p3)
    if is_eot(p4), do: result, else: raise("unexpected character")
  end

  defp read_value(p) do
    case p.current do
      ?n -> read_null(p)
      ?t -> read_true(p)
      ?f -> read_false(p)
      ?" -> read_string(p)
      ?[ -> read_array(p)
      ?{ -> read_object(p)
      c when c == ?- or (c >= ?0 and c <= ?9) -> read_number(p)
      _ -> raise "expected value"
    end
  end

  defp read_array(p0) do
    p1 = read(p0)
    p2 = skip_whitespace(p1)

    case read_char(p2, ?]) do
      {true, p3} -> {jarray_new(), p3}
      {false, p3} -> read_array_loop(jarray_new(), p3)
    end
  end

  defp read_array_loop(arr0, p0) do
    p1 = skip_whitespace(p0)
    {val, p2} = read_value(p1)
    arr1 = jarray_add(arr0, val)
    p3 = skip_whitespace(p2)

    case read_char(p3, ?,) do
      {true, p4} ->
        read_array_loop(arr1, p4)

      {false, p4} ->
        case read_char(p4, ?]) do
          {true, p5} -> {arr1, p5}
          {false, _} -> raise "expected ',' or ']'"
        end
    end
  end

  defp read_object(p0) do
    p1 = read(p0)
    p2 = skip_whitespace(p1)

    case read_char(p2, ?}) do
      {true, p3} -> {jobject_new(), p3}
      {false, p3} -> read_object_loop(jobject_new(), p3)
    end
  end

  defp read_object_loop(obj0, p0) do
    p1 = skip_whitespace(p0)
    {name, p2} = read_name(p1)
    p3 = skip_whitespace(p2)

    p4 =
      case read_char(p3, ?:) do
        {true, p4a} -> p4a
        {false, _} -> raise "expected ':'"
      end

    p5 = skip_whitespace(p4)
    {val, p6} = read_value(p5)
    obj1 = jobject_add(obj0, name, val)
    p7 = skip_whitespace(p6)

    case read_char(p7, ?,) do
      {true, p8} ->
        read_object_loop(obj1, p8)

      {false, p8} ->
        case read_char(p8, ?}) do
          {true, p9} -> {obj1, p9}
          {false, _} -> raise "expected ',' or '}'"
        end
    end
  end

  defp read_name(p) do
    case p.current do
      ?" -> read_string_internal(p)
      _ -> raise "expected name"
    end
  end

  defp read_null(p0) do
    p1 = read(p0)
    p2 = read_required_char(p1, ?u)
    p3 = read_required_char(p2, ?l)
    p4 = read_required_char(p3, ?l)
    {{:jliteral, :null}, p4}
  end

  defp read_true(p0) do
    p1 = read(p0)
    p2 = read_required_char(p1, ?r)
    p3 = read_required_char(p2, ?u)
    p4 = read_required_char(p3, ?e)
    {{:jliteral, true}, p4}
  end

  defp read_false(p0) do
    p1 = read(p0)
    p2 = read_required_char(p1, ?a)
    p3 = read_required_char(p2, ?l)
    p4 = read_required_char(p3, ?s)
    p5 = read_required_char(p4, ?e)
    {{:jliteral, false}, p5}
  end

  defp read_required_char(p, ch) do
    case read_char(p, ch) do
      {true, p1} -> p1
      {false, _} -> raise "expected #{<<ch>>}"
    end
  end

  defp read_string(p0) do
    {str, p1} = read_string_internal(p0)
    {{:jstring, str}, p1}
  end

  defp read_string_internal(p0) do
    p1 = read(p0)
    p2 = %{p1 | capture_start: p1.index}
    p3 = read_string_chars(p2)
    {string, p4} = end_capture(p3)
    p5 = read(p4)
    {string, p5}
  end

  defp read_string_chars(p) do
    case p.current do
      ?" ->
        p

      ?\\ ->
        p1 = pause_capture(p)
        p2 = read_escape(p1)
        p3 = %{p2 | capture_start: p2.index}
        read_string_chars(p3)

      _ ->
        read_string_chars(read(p))
    end
  end

  defp read_escape(p0) do
    p1 = read(p0)
    ch = p1.current

    buf =
      case ch do
        ?" -> <<p1.capture_buffer::binary, ?">>
        ?/ -> <<p1.capture_buffer::binary, ?/>>
        ?\\ -> <<p1.capture_buffer::binary, ?\\>>
        ?b -> <<p1.capture_buffer::binary, ?\b>>
        ?f -> <<p1.capture_buffer::binary, ?\f>>
        ?n -> <<p1.capture_buffer::binary, ?\n>>
        ?r -> <<p1.capture_buffer::binary, ?\r>>
        ?t -> <<p1.capture_buffer::binary, ?\t>>
        _ -> raise "expected valid escape sequence"
      end

    read(%{p1 | capture_buffer: buf})
  end

  defp read_number(p0) do
    p1 = %{p0 | capture_start: p0.index}
    {_, p2} = read_char(p1, ?-)
    first = p2.current

    p3 =
      case read_digit(p2) do
        {true, p3a} -> p3a
        {false, _} -> raise "expected digit"
      end

    p4 = if first == ?0, do: p3, else: read_digits(p3)
    p5 = read_fraction(p4)
    p6 = read_exponent(p5)
    {num_str, p7} = end_capture(p6)
    {{:jnumber, num_str}, p7}
  end

  defp read_digits(p) do
    case read_digit(p) do
      {true, p1} -> read_digits(p1)
      {false, p1} -> p1
    end
  end

  defp read_fraction(p) do
    case read_char(p, ?.) do
      {false, p1} ->
        p1

      {true, p1} ->
        case read_digit(p1) do
          {true, p2} -> read_digits(p2)
          {false, _} -> raise "expected digit"
        end
    end
  end

  defp read_exponent(p) do
    has =
      case read_char(p, ?e) do
        {true, _} = r -> r
        {false, _} -> read_char(p, ?E)
      end

    case has do
      {false, p1} ->
        p1

      {true, p1} ->
        p2 =
          case read_char(p1, ?+) do
            {true, px} ->
              px

            {false, px} ->
              case read_char(px, ?-) do
                {_, py} -> py
              end
          end

        case read_digit(p2) do
          {true, p3} -> read_digits(p3)
          {false, _} -> raise "expected digit"
        end
    end
  end

  defp read_char(p, ch) do
    if p.current === ch, do: {true, read(p)}, else: {false, p}
  end

  defp read_digit(p) do
    if is_digit(p), do: {true, read(p)}, else: {false, p}
  end

  defp skip_whitespace(p) do
    if is_whitespace(p), do: skip_whitespace(read(p)), else: p
  end

  defp read(%P{input: bin, index: i} = p) do
    new_i = i + 1

    cur =
      if new_i < byte_size(bin) do
        :binary.at(bin, new_i)
      else
        :eof
      end

    %{p | index: new_i, current: cur}
  end

  defp pause_capture(%P{index: i, capture_start: start, capture_buffer: buf, input: bin, current: cur} = p) do
    end_ = if cur == :eof, do: i, else: i - 1
    slice = :binary.part(bin, start, end_ - start + 1)
    %{p | capture_buffer: <<buf::binary, slice::binary>>, capture_start: -1}
  end

  defp end_capture(%P{index: i, capture_start: start, capture_buffer: buf, input: bin, current: cur} = p) do
    end_ = if cur == :eof, do: i, else: i - 1
    slice = :binary.part(bin, start, end_ - start + 1)

    captured =
      if buf == <<>> do
        slice
      else
        <<buf::binary, slice::binary>>
      end

    {captured, %{p | capture_start: -1, capture_buffer: <<>>}}
  end

  defp is_whitespace(%P{current: ?\s}), do: true
  defp is_whitespace(%P{current: ?\t}), do: true
  defp is_whitespace(%P{current: ?\n}), do: true
  defp is_whitespace(%P{current: ?\r}), do: true
  defp is_whitespace(_), do: false

  defp is_digit(%P{current: c}) when c >= ?0 and c <= ?9, do: true
  defp is_digit(_), do: false

  defp is_eot(%P{current: :eof}), do: true
  defp is_eot(_), do: false
end
