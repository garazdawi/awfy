defmodule Awfy.Benchmarks.Towers do
  @moduledoc """
  Towers of Hanoi — translated from upstream/benchmarks/Ruby/towers.rb.

  13-disk tower, counts moves (expected 8191 = 2^13 - 1). The Ruby
  original uses a TowersDisk linked list with a mutable `next` field;
  we use Elixir lists where the head is the top of the pile, with the
  three piles held in a 3-tuple. Disks are their integer size.
  """

  use Awfy.Benchmark

  def name, do: "Towers"

  def verify_result(result), do: result == 8191

  def benchmark do
    piles0 = {[], [], []}
    piles1 = build_tower_at(0, 13, piles0)
    {_piles2, moves} = move_disks(13, 0, 1, piles1, 0)
    moves
  end

  defp build_tower_at(_pile, i, piles) when i < 0, do: piles

  defp build_tower_at(pile, i, piles) do
    build_tower_at(pile, i - 1, push_disk(i, pile, piles))
  end

  defp push_disk(disk, pile, piles) do
    case top(pile, piles) do
      t when is_integer(t) and disk >= t ->
        raise "Cannot put a big disk on a smaller one"

      _ ->
        set_pile(pile, [disk | get_pile(pile, piles)], piles)
    end
  end

  defp pop_disk_from(pile, piles) do
    case get_pile(pile, piles) do
      [] -> raise "Attempting to remove a disk from an empty pile"
      [t | rest] -> {t, set_pile(pile, rest, piles)}
    end
  end

  defp move_top_disk(from, to, piles, moves) do
    {disk, piles1} = pop_disk_from(from, piles)
    piles2 = push_disk(disk, to, piles1)
    {piles2, moves + 1}
  end

  defp move_disks(1, from, to, piles, moves), do: move_top_disk(from, to, piles, moves)

  defp move_disks(disks, from, to, piles, moves) do
    other = 3 - from - to
    {piles1, moves1} = move_disks(disks - 1, from, other, piles, moves)
    {piles2, moves2} = move_top_disk(from, to, piles1, moves1)
    move_disks(disks - 1, other, to, piles2, moves2)
  end

  defp get_pile(0, {p, _, _}), do: p
  defp get_pile(1, {_, p, _}), do: p
  defp get_pile(2, {_, _, p}), do: p

  defp set_pile(0, p, {_, b, c}), do: {p, b, c}
  defp set_pile(1, p, {a, _, c}), do: {a, p, c}
  defp set_pile(2, p, {a, b, _}), do: {a, b, p}

  defp top(pile, piles) do
    case get_pile(pile, piles) do
      [] -> nil
      [t | _] -> t
    end
  end
end
