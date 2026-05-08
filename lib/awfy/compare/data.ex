# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Compare.Data do
  @moduledoc """
  Loads measurement runs from `results/` and assembles the flat
  dataset consumed by `mix awfy.compare` and `mix awfy.diff`.

  Public surface:

    * `load/2` — discover run dirs, decode each `meta.json` and every
      `*.benchee` file, return `%{runs: [...], rows: [...]}`.
    * `geomean_ratio/2` — suite-wide aggregate metric (geomean of
      per-benchmark `median_ms / baseline_median_ms`); used by both
      the dashboard index page and `mix awfy.diff`.

  A "row" is a single (run × benchmark × series-axis) measurement,
  flattened so the dashboard JS doesn't have to navigate Benchee's
  Suite struct. The series axis is whichever of `lang` (AWFY:
  `"erlang"` / `"elixir"`) or `input` (OtpBenchmarks: `"atom"`,
  `"binary_4k"`, …) the suite populated; the other field is `nil`.

      %{
        label: "v1",
        timestamp: "2026-05-01T12:34:56Z",
        otp: "28.4.1",
        elixir: "1.19.5",
        hostname: "lukas-m5",
        cpu: "Apple M5",
        arch: "aarch64-apple-darwin",
        emu_flavor: "jit",
        lang: "erlang",   # set for AWFY ports; nil for OtpBenchmarks
        input: nil,       # set for OtpBenchmarks scenarios; nil for AWFY
        benchmark: "Bounce",
        median_ms: 116.7,
        mean_ms: 116.4,
        stddev_ms: 0.8,
        samples_n: 9,
        inner_iter: 1500,
        source_sha256: "abc...",
        verified: true
      }
  """

  @doc """
  Discover run dirs under `root`, optionally filtering by label list.

  Returns `%{runs: [...meta...], rows: [...flat measurements...]}`.
  """
  @spec load(Path.t(), [String.t()] | nil) :: %{runs: [map()], rows: [map()]}
  def load(root \\ "results", labels \\ nil) do
    label_filter = if labels, do: MapSet.new(labels), else: nil

    run_dirs =
      case File.ls(root) do
        {:ok, names} ->
          names
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.filter(&File.exists?(Path.join(&1, "meta.json")))

        _ ->
          []
      end

    runs =
      run_dirs
      |> Enum.map(&load_run/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn run ->
        label_filter == nil or MapSet.member?(label_filter, run.label)
      end)
      |> Enum.sort_by(& &1.timestamp)

    rows = Enum.flat_map(runs, &rows_for_run/1)
    %{runs: runs, rows: rows}
  end

  defp load_run(dir) do
    meta_path = Path.join(dir, "meta.json")

    with {:ok, json} <- File.read(meta_path),
         {:ok, meta} <- Jason.decode(json) do
      %{
        dir: dir,
        label: get(meta, "label"),
        timestamp: get(meta, "timestamp"),
        otp: get(meta, "otp"),
        elixir: get(meta, "elixir"),
        format_version: get(meta, "format_version") || 0,
        machine: get(meta, "machine") || %{},
        runtime: get(meta, "runtime") || %{},
        config: get(meta, "config") || %{},
        git: get(meta, "git") || %{},
        benchmarks_meta: get(meta, "benchmarks") || [],
        otp_benchmarks_meta: get(meta, "otp_benchmarks") || []
      }
    else
      _ -> nil
    end
  end

  defp rows_for_run(run) do
    bench_paths =
      Path.wildcard(Path.join(run.dir, "*.benchee"))

    bench_paths
    |> Enum.flat_map(fn path ->
      bench_name = Path.basename(path, ".benchee")

      case decode_suite(path) do
        nil ->
          []

        suite ->
          per_bench_meta = bench_meta(run.benchmarks_meta, bench_name)
          inner_iter = get(per_bench_meta, "inner_iter")
          languages = get(per_bench_meta, "languages") || %{}

          # OtpBenchmarks rows look up source_sha256 from the family
          # entry in the run's `otp_benchmarks` meta block; AWFY rows
          # look it up per-language from the existing `benchmarks`
          # block. Either side hands back `nil` if the run-dir lacks
          # that metadata (e.g. a phash2.benchee dropped in by hand).
          otp_family_meta = otp_family_meta(run.otp_benchmarks_meta, bench_name)

          # Drop scenarios with a 0 ns median — those are sub-clock-floor
          # results (Windows' QueryPerformanceCounter has a ~102 μs
          # granularity, so for sub-µs benchmarks half or more of the
          # batch samples land on 0 ticks and the median collapses to
          # 0). Plotting them yields `baseline / 0 = Infinity`, which
          # spikes the chart's y-axis and visually crowds every other
          # series down to a flat line near zero. The data is real
          # noise, not a real measurement, so don't propagate it.
          suite.scenarios
          |> Enum.reject(fn s -> sub_clock_floor?(s.run_time_data.statistics) end)
          |> Enum.map(fn scenario ->
            {bname, lang} = parse_name(scenario.name)
            # Benchee sets `input_name` only when the suite was run
            # with `inputs: %{...}` — that's the OtpBenchmarks shape.
            # For AWFY suites it's the sentinel `Benchee.Benchmark.no_input/0`,
            # which we map to nil so the dashboard's series-axis
            # logic treats lang as the only series identifier.
            input = scenario_input_name(scenario)
            stats = scenario.run_time_data.statistics
            lang_meta = Map.get(languages, lang, %{})

            {source_sha256, verified} =
              if input do
                # Family is multi-input → meta lives in otp_benchmarks.
                # `verified` is unused for OtpBenchmarks today (no
                # verify_result/2); fall through to nil. Future ETS /
                # Mnesia smoke checks could populate it.
                {get(otp_family_meta, "source_sha256"), nil}
              else
                {get(lang_meta, "source_sha256"), get(lang_meta, "verified")}
              end

            %{
              label: run.label,
              timestamp: run.timestamp,
              otp: run.otp,
              elixir: run.elixir,
              hostname: get(run.machine, "hostname"),
              cpu: get(run.machine, "cpu"),
              arch: get(run.machine, "arch"),
              cores: get(run.machine, "cores"),
              emu_flavor: get(run.runtime, "emu_flavor"),
              schedulers_online: get(run.runtime, "schedulers_online"),
              lang: lang,
              input: input,
              benchmark: bname || bench_name,
              median_ms: ns_to_ms(stats.median),
              mean_ms: ns_to_ms(stats.average),
              stddev_ms: ns_to_ms(stats.std_dev),
              samples_n: stats.sample_size,
              inner_iter: inner_iter,
              source_sha256: source_sha256,
              verified: verified
            }
          end)
      end
    end)
  end

  defp decode_suite(path) do
    case File.read(path) do
      {:ok, bin} ->
        try do
          :erlang.binary_to_term(bin)
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp bench_meta(list, name) when is_list(list) do
    Enum.find(list, %{}, fn entry -> get(entry, "name") == name end)
  end

  defp bench_meta(_, _), do: %{}

  defp otp_family_meta(list, name) when is_list(list) do
    Enum.find(list, %{}, fn entry -> get(entry, "name") == name end)
  end

  defp otp_family_meta(_, _), do: %{}

  # Scenario names look like "Bounce/erlang (v1)" — extract benchmark + lang.
  defp parse_name(name) do
    base = String.split(name, " ", parts: 2) |> hd()

    case String.split(base, "/", parts: 2) do
      [bench, lang] -> {bench, lang}
      _ -> {nil, nil}
    end
  end

  # 6 decimal places preserves nanosecond resolution for
  # OtpBenchmarks-style sub-microsecond medians (12 ns rounds to
  # 0.000012 ms instead of 0.0). AWFY scenarios at the millisecond
  # scale lose nothing — the trailing zeros are noise.
  defp ns_to_ms(nil), do: nil
  defp ns_to_ms(ns) when is_number(ns), do: Float.round(ns / 1_000_000, 6)

  # A scenario is sub-clock-floor when its median run-time is 0 ns
  # — which only happens when more than half of the batch samples
  # finished within zero clock ticks. Treated as "no usable
  # measurement" since it neither plots nor folds into a geomean
  # cleanly. Conservative on purpose: legitimately fast benchmarks
  # on Apple Silicon (42 ns clock floor) still show up with a
  # nonzero multiple-of-floor median; only the truly-zero cases
  # are dropped.
  defp sub_clock_floor?(%Benchee.Statistics{median: m}) when is_number(m) and m <= 0, do: true
  defp sub_clock_floor?(%Benchee.Statistics{median: nil}), do: true
  defp sub_clock_floor?(_), do: false

  # Benchee fills `scenario.input_name` only when the suite was run
  # with an `inputs: %{...}` map. AWFY-shape suites (one timed
  # closure, no inputs) use the sentinel `Benchee.Benchmark.no_input`
  # — an atom — which the dashboard's series-axis logic should
  # treat as "no input variant", not as a literal value. Strings
  # are real OtpBenchmarks input names; anything else is a sentinel
  # we collapse to nil.
  defp scenario_input_name(%{input_name: name}) when is_binary(name), do: name
  defp scenario_input_name(_), do: nil

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  @doc """
  Geomean of `median_ms / baseline_median_ms` across the intersection
  of benchmarks present in *both* labels (per Q12 plan decision).

  Both `label_rows` and `baseline_rows` are lists of `rows_for_run`
  output filtered down to a single label and (optionally) a single
  language.

  Multi-input families (OtpBenchmarks scenarios where `input` is set)
  contribute one cell each to the geomean, computed as the geomean
  of their own input medians. So `phash2` weights equally with each
  AWFY benchmark — instead of dominating with 13 cells, or being
  excluded entirely. The trade-off: per-input regressions inside a
  family wash out in the suite headline; the per-family page surfaces
  them.
  """
  @spec geomean_ratio([map()], [map()]) :: {float(), [String.t()]}
  def geomean_ratio(label_rows, baseline_rows) do
    label_by_bench = index_by_benchmark(label_rows)
    base_by_bench = index_by_benchmark(baseline_rows)

    intersection =
      MapSet.intersection(
        MapSet.new(Map.keys(label_by_bench)),
        MapSet.new(Map.keys(base_by_bench))
      )
      |> MapSet.to_list()
      |> Enum.sort()

    dropped =
      MapSet.union(
        MapSet.new(Map.keys(label_by_bench)),
        MapSet.new(Map.keys(base_by_bench))
      )
      |> MapSet.difference(MapSet.new(intersection))
      |> MapSet.to_list()
      |> Enum.sort()

    case intersection do
      [] ->
        {nil, dropped}

      benches ->
        sum_log =
          Enum.reduce(benches, 0.0, fn b, acc ->
            ratio = Map.fetch!(label_by_bench, b) / Map.fetch!(base_by_bench, b)
            acc + :math.log(ratio)
          end)

        gm = :math.exp(sum_log / length(benches))
        {Float.round(gm, 4), dropped}
    end
  end

  defp index_by_benchmark(rows) do
    rows
    |> Enum.filter(& &1.median_ms)
    |> Enum.group_by(& &1.benchmark)
    |> Map.new(fn {bench, rs} -> {bench, group_median(rs)} end)
  end

  # AWFY rows have one cell per (lang, benchmark) — pick the
  # erlang cell to match the cross-language table convention.
  # OtpBenchmarks rows are multi-input — collapse the family's
  # cells into a single per-family geomean so the family weighs
  # equally with each AWFY benchmark in the suite-wide ratio.
  defp group_median(rows) do
    if Enum.any?(rows, fn r -> Map.get(r, :input) end) do
      family_geomean(rows)
    else
      pick =
        Enum.find(rows, &(&1.lang == "erlang")) ||
          Enum.find(rows, &(&1.lang == "elixir")) ||
          List.first(rows)

      pick.median_ms
    end
  end

  # Geometric mean of the family's per-input medians, computed in
  # log space so a 1 ns vs 6 µs spread doesn't lose precision.
  # Filters out missing / zero medians so a single failed input
  # doesn't sink the whole family to nil.
  defp family_geomean(rows) do
    medians =
      rows
      |> Enum.map(& &1.median_ms)
      |> Enum.filter(&(is_number(&1) and &1 > 0))

    case medians do
      [] ->
        nil

      _ ->
        sum_log = Enum.reduce(medians, 0.0, fn m, acc -> acc + :math.log(m) end)
        :math.exp(sum_log / length(medians))
    end
  end
end
