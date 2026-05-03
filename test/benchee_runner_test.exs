# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.BencheeRunnerTest do
  @moduledoc """
  Tests `Awfy.BencheeRunner` configuration accessors. Pinning these
  to expected values catches accidental edits to the calibration
  tables (`@default_inner_iter`, `@default_time`) — those values
  are upstream-tracking and shouldn't drift silently.
  """

  use ExUnit.Case, async: true

  describe "inner_iter_for/1" do
    test "returns calibrated inner_iter for known benchmarks" do
      # Spot-check several across the speed range, not every single
      # benchmark — the table itself is the source of truth, this is
      # just guarding against accidental edits.
      assert Awfy.BencheeRunner.inner_iter_for("Bounce") == 1500
      assert Awfy.BencheeRunner.inner_iter_for("NBody") == 250_000
      assert Awfy.BencheeRunner.inner_iter_for("Json") == 100
      assert Awfy.BencheeRunner.inner_iter_for("DeltaBlue") == 12_000
    end

    test "raises KeyError on unknown benchmark name" do
      assert_raise KeyError, fn ->
        Awfy.BencheeRunner.inner_iter_for("NotARealBenchmark")
      end
    end
  end

  describe "time_for/1" do
    test "returns calibrated :time for known benchmarks" do
      assert Awfy.BencheeRunner.time_for("Bounce") == 8
      assert Awfy.BencheeRunner.time_for("DeltaBlue") == 4
      assert Awfy.BencheeRunner.time_for("List") == 10
    end

    test "raises KeyError on unknown benchmark name" do
      assert_raise KeyError, fn -> Awfy.BencheeRunner.time_for("NotARealBenchmark") end
    end
  end

  test "every registered benchmark has a calibrated inner_iter and time" do
    # Source of truth: every benchmark in `Awfy.benchmarks()` MUST have
    # an entry in both calibration tables. A new port that's added
    # without updating these tables will fail this test.
    names = Awfy.benchmarks() |> Enum.map(&Awfy.name/1) |> Enum.uniq()

    Enum.each(names, fn name ->
      assert is_integer(Awfy.BencheeRunner.inner_iter_for(name)),
             "missing @default_inner_iter for #{name}"

      assert is_integer(Awfy.BencheeRunner.time_for(name)),
             "missing @default_time for #{name}"
    end)
  end
end
