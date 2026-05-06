# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.VersionedBench do
  @moduledoc """
  End-to-end smoke test for the versioned-bench pipeline:
  measure → compare → diff. Uses `--time 0 --warmup 0` for the
  Benchee invocations so the test runs in a couple of seconds.
  """

  use ExUnit.Case, async: false

  @tmp_root "tmp/versioned_bench_test_results"

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  test "measure writes meta.json + per-benchmark .benchee files" do
    Mix.Task.rerun("awfy.measure", [
      "--benchmarks",
      "Bounce",
      "--lang",
      "erlang",
      "--time",
      "1",
      "--warmup",
      "0",
      "--label",
      "test1",
      "--out",
      @tmp_root,
      # Filter is "Bounce" only — OtpBenchmarks pass would naturally
      # be a no-op (phash2 isn't in the filter), but pass the explicit
      # opt-out anyway so the test is robust to a future change that
      # auto-includes some default OtpBenchmarks family.
      "--no-otp-benchmarks"
    ])

    [run_dir] = File.ls!(@tmp_root) |> Enum.map(&Path.join(@tmp_root, &1))
    assert File.dir?(run_dir)

    meta_json = File.read!(Path.join(run_dir, "meta.json"))
    meta = Jason.decode!(meta_json)

    assert meta["format_version"] == 1
    assert meta["label"] == "test1"

    # `meta["otp"]` prefers the OTP_VERSION file (full "X.Y.Z[.P]"
    # string) over System.otp_release/0 (just the major). On a
    # normal OTP install the file is present, so locally this is
    # "28.4.1"-shaped; on a stripped install it falls back to "28".
    # See `Mix.Tasks.Awfy.Measure.otp_version_label/0`. CI sets
    # AWFY_OTP_VERSION explicitly to the dashboard-bucketed form
    # (e.g. "21.3"); we allow either shape here.
    release = to_string(System.otp_release())

    assert meta["otp"] == release or
             String.starts_with?(meta["otp"], release <> "."),
           "meta[\"otp\"]=#{inspect(meta["otp"])} expected to start with #{release}"

    assert meta["elixir"] == System.version()
    assert meta["machine"]["hostname"]
    assert meta["machine"]["cpu"]
    assert meta["runtime"]["emu_flavor"]
    assert meta["runtime"]["schedulers_online"]

    [bench_entry] = meta["benchmarks"]
    assert bench_entry["name"] == "Bounce"
    assert bench_entry["inner_iter"] == 1500
    assert bench_entry["languages"]["erlang"]["verified"] == true
    assert bench_entry["languages"]["erlang"]["source_sha256"] =~ ~r/^[0-9a-f]{64}$/

    assert File.exists?(Path.join(run_dir, "Bounce.benchee"))

    # `--no-otp-benchmarks` was set above; the OtpBenchmarks block
    # should be present but empty so dashboard loaders that check
    # for the field don't crash on missing keys.
    assert meta["otp_benchmarks"] == []
    refute File.exists?(Path.join(run_dir, "phash2.benchee"))
  end

  @tag timeout: 60_000
  test "measure --benchmarks phash2 runs the OtpBenchmarks pass" do
    # OtpBenchmarks-only run: AWFY filter ends empty, phash2 family
    # ends populated. This is the path GHA fill mode takes when
    # dispatched with `benchmarks=phash2` to backfill phash2 data
    # across SHAs.
    Mix.Task.rerun("awfy.measure", [
      "--benchmarks",
      "phash2",
      "--time",
      "1",
      "--warmup",
      "0",
      "--label",
      "test_phash2",
      "--out",
      @tmp_root
    ])

    [run_dir] = File.ls!(@tmp_root) |> Enum.map(&Path.join(@tmp_root, &1))
    assert File.exists?(Path.join(run_dir, "phash2.benchee"))
    refute File.exists?(Path.join(run_dir, "Bounce.benchee"))

    meta = Path.join(run_dir, "meta.json") |> File.read!() |> Jason.decode!()
    assert meta["benchmarks"] == []

    [phash2_entry] = meta["otp_benchmarks"]
    assert phash2_entry["name"] == "phash2"
    assert phash2_entry["source_sha256"] =~ ~r/^[0-9a-f]{64}$/

    # Pin the scenario list so an accidental drop or rename surfaces
    # here. This is the same set the OtpBenchmarks tests pin.
    assert phash2_entry["scenarios"] == [
             "atom",
             "binary_4k",
             "binary_64",
             "binary_8",
             "int_bignum",
             "int_fixnum",
             "list_10",
             "list_1000",
             "map_100",
             "map_32",
             "map_5",
             "tuple_10",
             "tuple_1000"
           ]
  end

  test "data loader extracts rows from saved runs" do
    measure_one("v1")
    measure_one("v2")

    %{runs: runs, rows: rows} = Awfy.Compare.Data.load(@tmp_root)
    assert length(runs) == 2
    assert Enum.map(runs, & &1.label) |> Enum.sort() == ["v1", "v2"]

    assert Enum.all?(rows, &(&1.benchmark == "Bounce"))
    assert Enum.all?(rows, &(&1.lang == "erlang"))
    assert Enum.all?(rows, &(&1.median_ms))
    assert Enum.all?(rows, &(&1.verified == true))
  end

  test "compare writes index.html and per-benchmark pages" do
    measure_one("v1")
    measure_one("v2")

    Mix.Task.rerun("awfy.compare", ["--out", @tmp_root])

    assert File.exists?(Path.join(@tmp_root, "index.html"))
    bench_html = File.read!(Path.join([@tmp_root, "per-bench", "Bounce.html"]))

    # Both labels appear in the embedded dataset
    assert bench_html =~ "\"label\":\"v1\""
    assert bench_html =~ "\"label\":\"v2\""
    # Chart.js + dashboard JS bound
    assert bench_html =~ "Chart("
    assert bench_html =~ "DATASET"
  end

  test "diff prints both labels' medians and a geomean row" do
    measure_one("v1")
    measure_one("v2")

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.rerun("awfy.diff", ["v1", "v2", "--out", @tmp_root])
      end)

    assert out =~ "Bounce/erlang"
    assert out =~ "v1 (ms)"
    assert out =~ "v2 (ms)"
    assert out =~ "Geomean"
  end

  defp measure_one(label) do
    Mix.Task.rerun("awfy.measure", [
      "--benchmarks",
      "Bounce",
      "--lang",
      "erlang",
      "--time",
      "1",
      "--warmup",
      "0",
      "--label",
      label,
      "--out",
      @tmp_root
    ])
  end
end
