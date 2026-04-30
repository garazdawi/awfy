defmodule Awfy.Benchmarks.Storage do
  @moduledoc """
  Storage — translated from upstream/benchmarks/Ruby/storage.rb.

  Recursively builds a tree of arrays. Stresses allocation and GC,
  since the result is discarded at every recursion level. Expected
  count is 5461.

  Ruby `Array.new(N)` is nil-filled; we use a tuple of nils, which
  is the BEAM equivalent of a heap-allocated fixed-size array.
  """

  use Awfy.Benchmark

  def name, do: "Storage"

  def verify_result(result), do: result == 5461

  def benchmark do
    seed = Awfy.Random.new()
    {_tree, _seed1, count} = build_tree_depth(7, seed, 0)
    count
  end

  defp build_tree_depth(1, seed, count) do
    {n, seed1} = Awfy.Random.next(seed)
    size = rem(n, 10) + 1
    {Tuple.duplicate(nil, size), seed1, count + 1}
  end

  defp build_tree_depth(depth, seed, count) do
    count1 = count + 1
    {c0, seed1, count2} = build_tree_depth(depth - 1, seed, count1)
    {c1, seed2, count3} = build_tree_depth(depth - 1, seed1, count2)
    {c2, seed3, count4} = build_tree_depth(depth - 1, seed2, count3)
    {c3, seed4, count5} = build_tree_depth(depth - 1, seed3, count4)
    {{c0, c1, c2, c3}, seed4, count5}
  end
end
