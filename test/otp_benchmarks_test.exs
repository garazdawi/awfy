# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarksTest do
  @moduledoc """
  Spike-level tests for the OtpBenchmarks framework: behaviour
  conformance for the phash2 family + an end-to-end smoke that the
  runner produces a `%Benchee.Suite{}` for every declared scenario.

  See `PLAN/EXTENDED_BENCH_PLAN.md` step 1.
  """

  use ExUnit.Case, async: false

  alias OtpBenchmarks.Benchmarks.Phash2
  alias Awfy.OtpBenchmarks.Runner

  describe "OtpBenchmarks registry" do
    test "phash2 is registered and findable by name" do
      assert Phash2 in OtpBenchmarks.benchmarks()
      assert OtpBenchmarks.fetch_by_name("phash2") == Phash2
      assert OtpBenchmarks.fetch_by_name("nope") == nil
    end
  end

  describe "Phash2 family" do
    test "name is stable" do
      assert Phash2.name() == "phash2"
    end

    test "declares non-trivial scenario coverage across input shapes" do
      keys = Phash2.inputs() |> Map.keys() |> MapSet.new()

      # Pin the surface area so accidental edits to the inputs map
      # surface here. Sizes / boundaries are documented in the
      # module's @moduledoc — they're upstream-tracking and shouldn't
      # drift silently.
      expected =
        MapSet.new([
          "atom",
          "int_fixnum",
          "int_bignum",
          "binary_8",
          "binary_64",
          "binary_4k",
          "list_10",
          "list_1000",
          "tuple_10",
          "tuple_1000",
          "map_5",
          "map_32",
          "map_100"
        ])

      assert keys == expected
    end

    test "run/1 returns an integer for every declared scenario" do
      for {name, input} <- Phash2.inputs() do
        assert is_integer(Phash2.run(input)),
               "phash2 returned non-integer for scenario #{inspect(name)}"
      end
    end

    test "default setup/1 is identity, teardown/1 is no-op" do
      assert Phash2.setup(:anything) == :anything
      assert Phash2.teardown(:anything) == :ok
    end
  end

  describe "Awfy.OtpBenchmarks.Runner" do
    @tag :tmp_dir
    test "writes a saved Benchee suite covering every scenario", %{tmp_dir: dir} do
      System.put_env("AWFY_NO_ISOLATION", "1")
      on_exit(fn -> System.delete_env("AWFY_NO_ISOLATION") end)

      # Tiny time / warmup so the test stays fast; we're checking
      # the wiring, not the numbers. Benchee will fire its
      # "fast warning" on a 1-ms time budget — silenced via
      # the runner's default opts.
      ExUnit.CaptureIO.capture_io(fn ->
        Runner.run_one(Phash2,
          benchee: [time: 0.05, warmup: 0, memory_time: 0, print: [fast_warning: false]],
          save_dir: dir,
          save_tag: "test"
        )
      end)

      saved = Path.join(dir, "phash2.benchee")
      assert File.exists?(saved)

      suite = saved |> File.read!() |> :erlang.binary_to_term()

      scenario_names =
        suite.scenarios
        |> Enum.map(fn s -> s.input_name end)
        |> MapSet.new()

      assert scenario_names == Phash2.inputs() |> Map.keys() |> MapSet.new()
    end
  end
end
