# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.RunnerTest do
  # Each test sets/clears env vars and writes to fixtures, so async
  # would race. Sub-test isolation matters more than parallelism for
  # 6-test surface area.
  use ExUnit.Case, async: false

  alias Awfy.Runner

  setup do
    on_exit(fn ->
      System.delete_env("AWFY_TARGET_ERL")
      System.delete_env("AWFY_TARGET_BUNDLE")
    end)

    :ok
  end

  describe "argv_for/4" do
    test "emits -pa for every bundle ebin and -extra for the positional payload" do
      bundle = bundle_fixture(["awfy_target_runner", "elixir", "benchee"])

      argv =
        Runner.argv_for(bundle, Bounce, 100,
          time: 5,
          warmup: 2,
          out: "/tmp/x.benchee"
        )

      ebin_args = pa_args(argv)

      # Every lib/*/ebin landed as a -pa.
      assert length(ebin_args) == 3

      assert Enum.all?(ebin_args, fn ebin ->
               String.contains?(ebin, "/lib/") and String.ends_with?(ebin, "/ebin")
             end)

      # Tail after `-extra` is the runner's positional contract:
      # module inner_iter time warmup out.
      assert ["Elixir.Bounce", "100", "5", "2", "/tmp/x.benchee"] ==
               drop_until(argv, "-extra")
    end

    test "Erlang module atom round-trips as bare lower-case name" do
      bundle = bundle_fixture(["awfy_target_runner"])

      argv = Runner.argv_for(bundle, :bounce, 1, out: "/tmp/o.benchee")
      assert hd(drop_until(argv, "-extra")) == "bounce"
    end

    test "extra_paths append to -pa flags" do
      bundle = bundle_fixture(["awfy_target_runner"])

      argv =
        Runner.argv_for(bundle, :bounce, 1,
          extra_paths: ["/some/extra/ebin"],
          out: "/tmp/o.benchee"
        )

      assert "/some/extra/ebin" in pa_args(argv)
    end

    test "fractional seconds render as Float.to_string" do
      bundle = bundle_fixture(["awfy_target_runner"])

      argv =
        Runner.argv_for(bundle, :bounce, 1,
          time: 1.5,
          warmup: 0.25,
          out: "/tmp/o.benchee"
        )

      assert ["bounce", "1", "1.5", "0.25", "/tmp/o.benchee"] ==
               drop_until(argv, "-extra")
    end
  end

  describe "otp_argv_for/3" do
    test "emits the --otp-benchmarks flag + family + time + warmup + out" do
      bundle = bundle_fixture(["awfy_target_runner", "otp_benchmarks"])

      argv =
        Runner.otp_argv_for(bundle, OtpBenchmarks.Benchmarks.Phash2,
          time: 3,
          warmup: 1,
          out: "/tmp/phash2.benchee"
        )

      assert ["--otp-benchmarks", "Elixir.OtpBenchmarks.Benchmarks.Phash2", "3", "1",
              "/tmp/phash2.benchee"] == drop_until(argv, "-extra")
    end

    test "shares the same -pa / -noshell prefix as argv_for/4" do
      bundle = bundle_fixture(["awfy_target_runner", "otp_benchmarks", "elixir"])

      otp_argv = Runner.otp_argv_for(bundle, OtpBenchmarks.Benchmarks.Phash2, out: "/tmp/x.benchee")
      awfy_argv = Runner.argv_for(bundle, Bounce, 100, out: "/tmp/y.benchee")

      assert pa_args(otp_argv) == pa_args(awfy_argv)
      # `-noshell -s Elixir.Awfy.TargetRunner main -extra` is shared.
      assert Enum.take(awfy_argv, length(pa_args(awfy_argv)) * 2) ==
               Enum.take(otp_argv, length(pa_args(otp_argv)) * 2)
    end
  end

  describe "run_otp_family/3 — config errors mirror run/4" do
    test ":no_target_erl when AWFY_TARGET_ERL unset" do
      bundle = bundle_fixture(["awfy_target_runner"])

      assert {:error, :no_target_erl} =
               Runner.run_otp_family(bundle, OtpBenchmarks.Benchmarks.Phash2)
    end

    test ":bundle_not_found when bundle dir doesn't exist" do
      System.put_env("AWFY_TARGET_ERL", System.find_executable("erl") || "/usr/bin/erl")

      assert {:error, {:bundle_not_found, "/nope/bundle"}} =
               Runner.run_otp_family("/nope/bundle", OtpBenchmarks.Benchmarks.Phash2)
    end
  end

  describe "run/4 — config errors are returned, not raised" do
    test ":no_target_erl when AWFY_TARGET_ERL unset and not in opts" do
      bundle = bundle_fixture(["awfy_target_runner"])

      assert {:error, :no_target_erl} = Runner.run(bundle, :bounce, 1, [])
    end

    test ":no_target_bundle when bundle path is nil and AWFY_TARGET_BUNDLE unset" do
      System.put_env("AWFY_TARGET_ERL", "/nonexistent/erl")

      assert {:error, :no_target_bundle} = Runner.run(nil, :bounce, 1, [])
    end

    test ":erl_not_found when the configured erl path doesn't exist" do
      bundle = bundle_fixture(["awfy_target_runner"])

      assert {:error, {:erl_not_found, "/nope/erl"}} =
               Runner.run(bundle, :bounce, 1, erl: "/nope/erl")
    end

    test ":bundle_not_found when bundle dir doesn't exist" do
      System.put_env("AWFY_TARGET_ERL", System.find_executable("erl") || "/usr/bin/erl")

      assert {:error, {:bundle_not_found, "/nope/bundle"}} =
               Runner.run("/nope/bundle", :bounce, 1, [])
    end
  end

  defp bundle_fixture(sub_apps) do
    bundle = Path.join(System.tmp_dir!(), "awfy-runner-bundle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(bundle) end)

    Enum.each(sub_apps, fn app ->
      File.mkdir_p!(Path.join([bundle, "lib", app, "ebin"]))
    end)

    bundle
  end

  defp pa_args(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["-pa", path] -> [path]
      _ -> []
    end)
  end

  defp drop_until([h | t], h), do: t
  defp drop_until([_ | t], target), do: drop_until(t, target)
  defp drop_until([], _), do: []
end
