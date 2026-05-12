# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.HelpersTest do
  @moduledoc """
  Pinning tests for the run-dir/label naming. The format is parsed
  back by `Mix.Tasks.Awfy.Fill.parse_run_dir/1`, so a silent change
  here would make every gh-pages-published run invisible to the fill
  task.
  """

  use ExUnit.Case, async: true

  alias Awfy.Measure.Helpers

  @now DateTime.from_iso8601("2026-04-15T09:30:00Z") |> elem(1)

  describe "basic_ts/1" do
    test "13-char basic ISO without Z" do
      assert Helpers.basic_ts(@now) == "20260415T0930"
      assert String.length(Helpers.basic_ts(@now)) == 13
    end
  end

  describe "auto_label/3" do
    test "clean tree → bare SHA (collides deterministically across re-runs)" do
      assert Helpers.auto_label("abc1234", false, @now) == "abc1234"
    end

    test "dirty tree → SHA + timestamp suffix" do
      assert Helpers.auto_label("abc1234", true, @now) == "abc1234-dirty_20260415T0930"
    end
  end

  describe "run_dir/5" do
    test "matches the regex Fill.parse_run_dir/1 expects" do
      dir = Helpers.run_dir("results", "abc1234-macos-arm64-jit", @now, "28", "1.19.5")
      assert dir == "results/20260415T0930_otp28_elixir1.19.5_abc1234-macos-arm64-jit"

      basename = Path.basename(dir)

      assert Regex.match?(
               ~r/^(\d{8}T\d{4})_otp([^_]+)_elixir([^_]+)_(.+)$/,
               basename
             )
    end
  end

  describe "parse_lang/1" do
    test "nil and \"both\" → :both" do
      assert Helpers.parse_lang(nil) == :both
      assert Helpers.parse_lang("both") == :both
    end

    test "specific languages" do
      assert Helpers.parse_lang("erlang") == :erlang
      assert Helpers.parse_lang("elixir") == :elixir
    end

    test "unknown raises Mix.Error" do
      assert_raise Mix.Error, fn -> Helpers.parse_lang("rust") end
    end
  end

  describe "parse_benchmarks/1" do
    test "nil → nil (no filter)" do
      assert Helpers.parse_benchmarks(nil) == nil
    end

    test "comma-separated, trims empties" do
      assert Helpers.parse_benchmarks("Bounce,Json") == ["Bounce", "Json"]
      assert Helpers.parse_benchmarks("Bounce,,Json,") == ["Bounce", "Json"]
    end
  end

  describe "filter_lang/2" do
    test ":both is identity" do
      entries = [{:erlang, :a}, {:elixir, :b}]
      assert Helpers.filter_lang(entries, :both) == entries
    end

    test "filters to one language" do
      entries = [{:erlang, :a}, {:elixir, :b}, {:erlang, :c}]
      assert Helpers.filter_lang(entries, :erlang) == [{:erlang, :a}, {:erlang, :c}]
      assert Helpers.filter_lang(entries, :elixir) == [{:elixir, :b}]
    end
  end

  describe "filter_benchmarks/2" do
    test "nil names → identity" do
      entries = Awfy.benchmarks() |> Enum.take(3)
      assert Helpers.filter_benchmarks(entries, nil) == entries
    end

    test "filters by Awfy.name/1" do
      entries = Awfy.benchmarks()
      filtered = Helpers.filter_benchmarks(entries, ["Bounce"])
      assert filtered != []
      assert Enum.all?(filtered, fn e -> Awfy.name(e) == "Bounce" end)
    end

    test "unknown name → empty" do
      assert Helpers.filter_benchmarks(Awfy.benchmarks(), ["NotARealBenchmark"]) == []
    end
  end

  describe "safe_integer/1" do
    test ":unknown → nil" do
      assert Helpers.safe_integer(:unknown) == nil
    end

    test "integer passthrough" do
      assert Helpers.safe_integer(8) == 8
      assert Helpers.safe_integer(0) == 0
    end

    test "garbage → nil (defensive)" do
      assert Helpers.safe_integer("8") == nil
      assert Helpers.safe_integer(nil) == nil
    end
  end

  describe "maybe_put/3" do
    test "nil value is skipped (don't override Benchee defaults)" do
      assert Helpers.maybe_put([memory_time: 0], :time, nil) == [memory_time: 0]
    end

    test "non-nil value is set" do
      assert Helpers.maybe_put([], :time, 5) == [time: 5]
    end
  end

  describe "otp_version_label/0" do
    # async: true at the top of the file is fine even with env-var
    # manipulation as long as each test wraps its mutation in
    # System.put_env / System.delete_env and resets in `after`. We
    # don't read AWFY_OTP_VERSION concurrently from anywhere else
    # during tests.
    test "AWFY_OTP_VERSION wins when set" do
      System.put_env("AWFY_OTP_VERSION", "27.3.4.11")
      assert Helpers.otp_version_label() == "27.3.4.11"
    after
      System.delete_env("AWFY_OTP_VERSION")
    end

    test "empty AWFY_OTP_VERSION falls through to file/release" do
      System.put_env("AWFY_OTP_VERSION", "")
      # Whatever the host's release is, it's not the empty string.
      assert Helpers.otp_version_label() != ""
    after
      System.delete_env("AWFY_OTP_VERSION")
    end

    test "falls back to System.otp_release when env var unset and no OTP_VERSION file" do
      System.delete_env("AWFY_OTP_VERSION")
      # The host's OTP_VERSION file usually exists, so this lands on
      # the file or the System.otp_release tail. Either way the value
      # is non-empty and matches the release major prefix.
      label = Helpers.otp_version_label()
      assert is_binary(label) and label != ""
      assert String.starts_with?(label, to_string(System.otp_release()))
    end
  end

  describe "trend_timestamp/0" do
    test "AWFY_OTP_COMMIT_TIMESTAMP wins when set to valid ISO 8601" do
      iso = "2022-06-23T12:34:56Z"
      System.put_env("AWFY_OTP_COMMIT_TIMESTAMP", iso)
      dt = Helpers.trend_timestamp()
      assert DateTime.to_iso8601(dt) == iso
    after
      System.delete_env("AWFY_OTP_COMMIT_TIMESTAMP")
    end

    test "missing env var falls back to wall-clock" do
      System.delete_env("AWFY_OTP_COMMIT_TIMESTAMP")
      before = DateTime.utc_now()
      dt = Helpers.trend_timestamp()
      after_ = DateTime.utc_now()
      assert DateTime.compare(dt, before) in [:eq, :gt]
      assert DateTime.compare(dt, after_) in [:eq, :lt]
    end

    test "malformed env var warns and falls back" do
      System.put_env("AWFY_OTP_COMMIT_TIMESTAMP", "not-a-date")

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        dt = Helpers.trend_timestamp()
        assert %DateTime{} = dt
      end)
    after
      System.delete_env("AWFY_OTP_COMMIT_TIMESTAMP")
    end
  end
end
