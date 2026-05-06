# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.TargetRunnerTest do
  use ExUnit.Case, async: true

  alias Awfy.TargetRunner

  describe "parse_args/1" do
    test "happy path: 5 positional args" do
      assert %{
               module: Bounce,
               inner_iter: 100,
               time: 5,
               warmup: 2,
               out: "/tmp/out.benchee"
             } == TargetRunner.parse_args(["Elixir.Bounce", "100", "5", "2", "/tmp/out.benchee"])
    end

    test "Erlang module atom" do
      assert %{module: :bounce} =
               TargetRunner.parse_args(["bounce", "100", "5", "2", "/tmp/out.benchee"])
    end

    test "fractional seconds (float) for time/warmup" do
      assert %{time: 1.5, warmup: 0.25} =
               TargetRunner.parse_args(["bounce", "1", "1.5", "0.25", "/tmp/out.benchee"])
    end

    test "bad arity raises" do
      assert_raise ArgumentError, ~r/expected 5 plain args/, fn ->
        TargetRunner.parse_args(["bounce"])
      end
    end

    test "non-numeric inner_iter raises" do
      assert_raise ArgumentError, fn ->
        TargetRunner.parse_args(["bounce", "lots", "5", "2", "/tmp/out.benchee"])
      end
    end

    test "non-numeric time raises with field name" do
      assert_raise ArgumentError, ~r/^time:/, fn ->
        TargetRunner.parse_args(["bounce", "1", "soon", "2", "/tmp/out.benchee"])
      end
    end

    test "non-numeric warmup raises with field name" do
      assert_raise ArgumentError, ~r/^warmup:/, fn ->
        TargetRunner.parse_args(["bounce", "1", "5", "soon", "/tmp/out.benchee"])
      end
    end
  end

  describe "run/1 — `.benchee` output shape" do
    # End-to-end: drive run/1 with a stub benchmark module, then
    # round-trip the saved suite through Benchee.load/1 and verify
    # the host's compare-data path can read the same shape.
    defmodule StubBench do
      def benchmark(_inner_iter), do: :ok
    end

    test "writes a Benchee.Suite that the host's binary_to_term path can read" do
      out =
        Path.join(
          System.tmp_dir!(),
          "awfy-target-runner-#{System.unique_integer([:positive])}.benchee"
        )

      on_exit(fn -> File.rm(out) end)

      config = %{
        module: StubBench,
        inner_iter: 1,
        # Sub-second budget keeps the test under ~250ms while still
        # giving Benchee enough samples to populate statistics.
        time: 0.05,
        warmup: 0.01,
        out: out
      }

      suite = TargetRunner.run(config)
      assert %Benchee.Suite{} = suite

      # Benchee's TaggedSave formatter writes term_to_binary directly
      # to `<out>` (no `.benchee` suffix munging when the path already
      # has one). Host reads it back via `File.read!/1` +
      # `:erlang.binary_to_term/1` — same path as
      # `lib/awfy/compare/data.ex:151`.
      assert File.exists?(out), "expected Benchee to write #{out}"

      loaded = out |> File.read!() |> :erlang.binary_to_term()
      assert %Benchee.Suite{} = loaded

      assert [%Benchee.Scenario{job_name: "Awfy.TargetRunnerTest.StubBench"} | _] =
               loaded.scenarios
    end
  end
end
