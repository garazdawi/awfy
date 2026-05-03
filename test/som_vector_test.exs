# SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: MIT

defmodule AwfyTest.SomVector do
  @moduledoc """
  Smoke tests for the Erlang SOM Vector port. Ensures it behaves like
  Ruby's Vector for the operations DeltaBlue/Havlak rely on.
  """

  use ExUnit.Case, async: true

  test "new vector is empty" do
    v = :awfy_som_vector.new()
    assert :awfy_som_vector.is_empty(v)
    assert :awfy_som_vector.size(v) == 0
  end

  test "append + size + at" do
    v =
      :awfy_som_vector.new()
      |> :awfy_som_vector.append(:a)
      |> :awfy_som_vector.append(:b)
      |> :awfy_som_vector.append(:c)

    assert :awfy_som_vector.size(v) == 3
    assert :awfy_som_vector.at(v, 0) == :a
    assert :awfy_som_vector.at(v, 1) == :b
    assert :awfy_som_vector.at(v, 2) == :c
  end

  test "with/1 starts with one element" do
    v = :awfy_som_vector.with(:hello)
    assert :awfy_som_vector.size(v) == 1
    assert :awfy_som_vector.first(v) == :hello
  end

  test "remove_first" do
    v =
      :awfy_som_vector.new()
      |> :awfy_som_vector.append(1)
      |> :awfy_som_vector.append(2)
      |> :awfy_som_vector.append(3)

    {x, v1} = :awfy_som_vector.remove_first(v)
    assert x == 1
    assert :awfy_som_vector.size(v1) == 2
    assert :awfy_som_vector.first(v1) == 2
  end

  test "at_put grows storage" do
    v = :awfy_som_vector.new() |> :awfy_som_vector.at_put(50, :far)
    assert :awfy_som_vector.at(v, 50) == :far
    assert :awfy_som_vector.size(v) == 51
  end

  test "each visits in order" do
    v =
      :awfy_som_vector.new()
      |> :awfy_som_vector.append(1)
      |> :awfy_som_vector.append(2)
      |> :awfy_som_vector.append(3)

    parent = self()
    :awfy_som_vector.each(v, fn x -> send(parent, {:e, x}) end)
    assert_received {:e, 1}
    assert_received {:e, 2}
    assert_received {:e, 3}
  end

  test "has_some" do
    v =
      :awfy_som_vector.new()
      |> :awfy_som_vector.append(1)
      |> :awfy_som_vector.append(2)
      |> :awfy_som_vector.append(3)

    assert :awfy_som_vector.has_some(v, fn x -> x == 2 end)
    refute :awfy_som_vector.has_some(v, fn x -> x == 99 end)
  end

  test "remove found and not-found" do
    v =
      :awfy_som_vector.new()
      |> :awfy_som_vector.append(:a)
      |> :awfy_som_vector.append(:b)
      |> :awfy_som_vector.append(:c)

    {found, v1} = :awfy_som_vector.remove(v, :b)
    assert found
    assert :awfy_som_vector.size(v1) == 2

    {not_found, v2} = :awfy_som_vector.remove(v, :z)
    refute not_found
    assert :awfy_som_vector.size(v2) == 3
  end

  test "sort orders elements" do
    v =
      :awfy_som_vector.new()
      |> :awfy_som_vector.append(3)
      |> :awfy_som_vector.append(1)
      |> :awfy_som_vector.append(4)
      |> :awfy_som_vector.append(1)
      |> :awfy_som_vector.append(5)
      |> :awfy_som_vector.append(9)
      |> :awfy_som_vector.append(2)
      |> :awfy_som_vector.append(6)

    sorted = :awfy_som_vector.sort(v, fn a, b -> a <= b end)
    out = for i <- 0..7, do: :awfy_som_vector.at(sorted, i)
    assert out == Enum.sort(out)
  end
end
