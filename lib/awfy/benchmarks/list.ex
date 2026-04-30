defmodule Awfy.Benchmarks.List do
  @moduledoc """
  List — translated from upstream/benchmarks/Ruby/list.rb.

  A custom singly-linked list with `val` and `next` fields, recursive
  length, and a tail-recursive shape comparator. We deliberately use a
  struct rather than Elixir's native lists — the benchmark is testing
  pointer-chasing through a heap-allocated structure, and native lists
  would short-circuit that with the JIT's list-specific optimizations.
  """

  use Awfy.Benchmark

  defmodule Element do
    defstruct val: nil, next: nil
  end

  def name, do: "List"

  def verify_result(result), do: result == 10

  def benchmark do
    result = tail(make_list(15), make_list(10), make_list(6))
    length_of(result)
  end

  defp make_list(0), do: nil
  defp make_list(n), do: %Element{val: n, next: make_list(n - 1)}

  defp length_of(nil), do: 0
  defp length_of(%Element{next: next}), do: 1 + length_of(next)

  defp is_shorter_than(x, y), do: is_shorter_loop(x, y)

  defp is_shorter_loop(_x, nil), do: false
  defp is_shorter_loop(nil, _y), do: true
  defp is_shorter_loop(%Element{next: xn}, %Element{next: yn}), do: is_shorter_loop(xn, yn)

  defp tail(x, y, z) do
    if is_shorter_than(y, x) do
      tail(
        tail(x.next, y, z),
        tail(y.next, z, x),
        tail(z.next, x, y)
      )
    else
      z
    end
  end
end
