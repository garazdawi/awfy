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
      @tmp_root
    ])

    [run_dir] = File.ls!(@tmp_root) |> Enum.map(&Path.join(@tmp_root, &1))
    assert File.dir?(run_dir)

    meta_json = File.read!(Path.join(run_dir, "meta.json"))
    {meta, _, _} = :json.decode(meta_json, :ok, %{})

    assert meta["format_version"] == 1
    assert meta["label"] == "test1"
    assert meta["otp"] == to_string(System.otp_release())
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
