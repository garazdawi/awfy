defmodule Awfy.Som.Vector do
  @moduledoc """
  SOM Vector — translated from upstream/benchmarks/Ruby/som.rb.

  Dynamic array with a sliding window (`first_idx`/`last_idx`) so
  `remove_first` is O(1). Backed by Erlang's `:array` module.

  All functions take the vector as the first argument so they pipe
  cleanly.
  """

  defstruct storage: nil, first_idx: 0, last_idx: 0

  @initial_size 10

  def new, do: %__MODULE__{}

  def new(size) when size > 0 do
    %__MODULE__{storage: :array.new(size, default: nil)}
  end

  def new(0), do: new()

  def with(elem), do: append(new(1), elem)

  def at(%__MODULE__{storage: nil}, _idx), do: nil

  def at(%__MODULE__{storage: storage}, idx) do
    if idx >= :array.size(storage) do
      nil
    else
      :array.get(idx, storage)
    end
  end

  def at_put(%__MODULE__{storage: nil} = v, idx, val) do
    size = max(idx + 1, @initial_size)
    storage = :array.new(size, default: nil)
    at_put(%{v | storage: storage}, idx, val)
  end

  def at_put(%__MODULE__{storage: storage, last_idx: last} = v, idx, val) do
    storage_sz = :array.size(storage)

    storage1 =
      if idx >= storage_sz do
        new_len = grow_to(storage_sz * 2, idx)
        resize_array(storage, new_len)
      else
        storage
      end

    storage2 = :array.set(idx, val, storage1)
    new_last = max(last, idx + 1)
    %{v | storage: storage2, last_idx: new_last}
  end

  defp grow_to(cur, idx) when cur > idx, do: cur
  defp grow_to(cur, idx), do: grow_to(cur * 2, idx)

  defp resize_array(old, new_len) do
    old_len = :array.size(old)
    new = :array.new(new_len, default: nil)
    copy_array(0, old_len, old, new)
  end

  defp copy_array(i, old_len, _old, new) when i >= old_len, do: new

  defp copy_array(i, old_len, old, new) do
    copy_array(i + 1, old_len, old, :array.set(i, :array.get(i, old), new))
  end

  def append(%__MODULE__{storage: nil} = v, elem) do
    storage = :array.new(@initial_size, default: nil)
    storage1 = :array.set(0, elem, storage)
    %{v | storage: storage1, last_idx: 1}
  end

  def append(%__MODULE__{storage: storage, last_idx: last} = v, elem) do
    storage_sz = :array.size(storage)

    storage1 =
      if last >= storage_sz do
        resize_array(storage, 2 * storage_sz)
      else
        storage
      end

    storage2 = :array.set(last, elem, storage1)
    %{v | storage: storage2, last_idx: last + 1}
  end

  def first(%__MODULE__{storage: nil}), do: nil

  def first(%__MODULE__{first_idx: f, last_idx: l}) when f >= l, do: nil

  def first(%__MODULE__{first_idx: f, storage: storage}), do: :array.get(f, storage)

  def remove_first(%__MODULE__{first_idx: f, last_idx: l} = v) when f >= l, do: {nil, v}

  def remove_first(%__MODULE__{first_idx: f, storage: storage} = v) do
    {:array.get(f, storage), %{v | first_idx: f + 1}}
  end

  def remove(%__MODULE__{storage: nil} = v, _obj), do: {false, v}

  def remove(%__MODULE__{first_idx: f, last_idx: l} = v, _obj) when f >= l, do: {false, v}

  def remove(%__MODULE__{storage: storage} = v, obj) do
    cap = :array.size(storage)
    new_arr = :array.new(cap, default: nil)
    {found, new_last, new_arr1} = remove_loop(v, obj, new_arr, 0, false)

    if found do
      {true, %{v | storage: new_arr1, first_idx: 0, last_idx: new_last}}
    else
      {false, v}
    end
  end

  defp remove_loop(
         %__MODULE__{first_idx: first, last_idx: last, storage: storage},
         obj,
         new_arr,
         new_last,
         found
       ) do
    remove_loop_iter(first, last, storage, obj, new_arr, new_last, found)
  end

  defp remove_loop_iter(i, last, _storage, _obj, new_arr, new_last, found) when i >= last do
    {found, new_last, new_arr}
  end

  defp remove_loop_iter(i, last, storage, obj, new_arr, new_last, found) do
    item = :array.get(i, storage)

    if item === obj do
      remove_loop_iter(i + 1, last, storage, obj, new_arr, new_last, true)
    else
      remove_loop_iter(
        i + 1,
        last,
        storage,
        obj,
        :array.set(new_last, item, new_arr),
        new_last + 1,
        found
      )
    end
  end

  def remove_all(%__MODULE__{storage: nil} = v), do: v

  def remove_all(%__MODULE__{storage: storage} = v) do
    %{
      v
      | storage: :array.new(:array.size(storage), default: nil),
        first_idx: 0,
        last_idx: 0
    }
  end

  def each(%__MODULE__{storage: nil}, _fun), do: :ok

  def each(%__MODULE__{first_idx: first, last_idx: last, storage: storage}, fun) do
    each_loop(first, last, storage, fun)
  end

  defp each_loop(i, last, _storage, _fun) when i >= last, do: :ok

  defp each_loop(i, last, storage, fun) do
    fun.(:array.get(i, storage))
    each_loop(i + 1, last, storage, fun)
  end

  def has_some(%__MODULE__{storage: nil}, _fun), do: false

  def has_some(%__MODULE__{first_idx: first, last_idx: last, storage: storage}, fun) do
    has_some_loop(first, last, storage, fun)
  end

  defp has_some_loop(i, last, _storage, _fun) when i >= last, do: false

  defp has_some_loop(i, last, storage, fun) do
    if fun.(:array.get(i, storage)) do
      true
    else
      has_some_loop(i + 1, last, storage, fun)
    end
  end

  def get_one(%__MODULE__{storage: nil}, _fun), do: nil

  def get_one(%__MODULE__{first_idx: first, last_idx: last, storage: storage}, fun) do
    get_one_loop(first, last, storage, fun)
  end

  defp get_one_loop(i, last, _storage, _fun) when i >= last, do: nil

  defp get_one_loop(i, last, storage, fun) do
    item = :array.get(i, storage)

    if fun.(item) do
      item
    else
      get_one_loop(i + 1, last, storage, fun)
    end
  end

  def size(%__MODULE__{first_idx: first, last_idx: last}), do: last - first

  def capacity(%__MODULE__{storage: nil}), do: 0
  def capacity(%__MODULE__{storage: storage}), do: :array.size(storage)

  def is_empty(%__MODULE__{first_idx: f, last_idx: l}), do: f === l

  def sort(%__MODULE__{first_idx: f, last_idx: l} = v, _cmp) when l - f <= 1, do: v

  def sort(%__MODULE__{first_idx: f, last_idx: l, storage: storage} = v, cmp) do
    storage1 = sort_range(f, l - 1, storage, cmp)
    %{v | storage: storage1}
  end

  defp sort_range(i, j, storage, _cmp) when j + 1 - i <= 1, do: storage

  defp sort_range(i, j, storage, cmp) do
    di = :array.get(i, storage)
    dj = :array.get(j, storage)

    {storage1, di1, dj1} =
      if cmp.(di, dj) do
        {storage, di, dj}
      else
        {swap_arr(i, j, storage), dj, di}
      end

    n = j + 1 - i

    if n > 2 do
      ij = div(i + j, 2)
      dij0 = :array.get(ij, storage1)

      {storage2, dij} =
        if cmp.(di1, dij0) do
          if cmp.(dij0, dj1) do
            {storage1, dij0}
          else
            {swap_arr(j, ij, storage1), dj1}
          end
        else
          {swap_arr(i, ij, storage1), di1}
        end

      if n > 3 do
        {storage3, k, l1} = partition(i, j - 1, storage2, dij, cmp)
        storage4 = sort_range(i, l1, storage3, cmp)
        sort_range(k, j, storage4, cmp)
      else
        storage2
      end
    else
      storage1
    end
  end

  defp partition(i, j, storage, dij, cmp), do: partition_loop(i, j, storage, dij, cmp)

  defp partition_loop(k, l, storage, dij, cmp) do
    l1 = decr_while_succeeds(l, k, storage, dij, cmp)
    k2 = incr_while_succeeds(k + 1, l1, storage, dij, cmp)

    if k2 <= l1 do
      partition_loop(k2, l1, swap_arr(k2, l1, storage), dij, cmp)
    else
      {storage, k2, l1}
    end
  end

  defp decr_while_succeeds(l, k, storage, dij, cmp) when k <= l do
    if cmp.(dij, :array.get(l, storage)) do
      decr_while_succeeds(l - 1, k, storage, dij, cmp)
    else
      l
    end
  end

  defp decr_while_succeeds(l, _k, _storage, _dij, _cmp), do: l

  defp incr_while_succeeds(k, l, storage, dij, cmp) when k <= l do
    if cmp.(:array.get(k, storage), dij) do
      incr_while_succeeds(k + 1, l, storage, dij, cmp)
    else
      k
    end
  end

  defp incr_while_succeeds(k, _l, _storage, _dij, _cmp), do: k

  defp swap_arr(i, j, storage) do
    vi = :array.get(i, storage)
    vj = :array.get(j, storage)
    :array.set(j, vi, :array.set(i, vj, storage))
  end
end
