defmodule Awfy.Benchmarks.Permute do
  @moduledoc """
  Permute — translated from upstream/benchmarks/Ruby/permute.rb.

  Recursively counts permutations of a 6-element array. Uses a 6-tuple
  with `put_elem/3`; copying 6 words per swap is cheap and matches the
  Ruby mutable-array semantics structurally.
  """

  use Awfy.Benchmark

  def name, do: "Permute"

  def verify_result(result), do: result == 8660

  def benchmark do
    v = Tuple.duplicate(0, 6)
    {count, _v1} = permute(6, 0, v)
    count
  end

  defp permute(0, count, v), do: {count + 1, v}

  defp permute(n, count, v) do
    count1 = count + 1
    n1 = n - 1
    {count2, v1} = permute(n1, count1, v)
    permute_outer(n1, n1, count2, v1)
  end

  defp permute_outer(i, _n1, count, v) when i < 0, do: {count, v}

  defp permute_outer(i, n1, count, v) do
    v1 = swap(n1, i, v)
    {count1, v2} = permute(n1, count, v1)
    v3 = swap(n1, i, v2)
    permute_outer(i - 1, n1, count1, v3)
  end

  # Tuples are 0-indexed in Elixir's put_elem/3; permute uses 0-indexed positions.
  defp swap(i, j, v) do
    tmp = elem(v, i)
    v1 = put_elem(v, i, elem(v, j))
    put_elem(v1, j, tmp)
  end
end
