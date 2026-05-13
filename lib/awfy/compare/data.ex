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
        otp_benchmarks_meta: get(meta, "otp_benchmarks") || [],
        applications_meta: get(meta, "applications") || [],
        # Raw per-second sample series for application benchmarks,
        # keyed by full benchmark name (e.g. "xmpp_cpu" → cpu_pct
        # array). Drives the stability drill-down sparkline.
        samples_by_bench: samples_by_bench(meta)
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
            {bname, lang} = identify_scenario(scenario.name, bench_name, languages)
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
              # Trust the label's flavor suffix over runtime.emu_flavor
              # for legacy runs on gh-pages: pre-Awfy.RunContext writers
              # recorded the *host* BEAM's emu_flavor, mis-tagging every
              # pre-24 bundle run or container-orchestrated XMPP run.
              # New writers resolve the flavor at write time (label
              # suffix wins, with a `runtime.flavor_source` tag noting
              # the choice) so on a fresh run `runtime.emu_flavor` IS
              # the truth; the fallback below stays only until every
              # gh-pages-archived run pre-dating the writer fix has
              # rolled off the dashboard. See PLAN/INFRA_REFACTOR.md § 3
              # for the resolution-history.
              emu_flavor: flavor_from_label(run.label) || get(run.runtime, "emu_flavor"),
              schedulers_online: get(run.runtime, "schedulers_online"),
              lang: lang,
              input: input,
              benchmark: bname || bench_name,
              median_ms: ns_to_ms(stats.median),
              mean_ms: ns_to_ms(stats.average),
              stddev_ms: ns_to_ms(stats.std_dev),
              min_ms: ns_to_ms(Map.get(stats, :minimum)),
              max_ms: ns_to_ms(Map.get(stats, :maximum)),
              p25_ms: ns_to_ms(get_percentile(stats, 25)),
              p75_ms: ns_to_ms(get_percentile(stats, 75)),
              p99_ms: ns_to_ms(get_percentile(stats, 99)),
              samples_n: stats.sample_size,
              inner_iter: inner_iter,
              source_sha256: source_sha256,
              verified: verified,
              # `category` / `family` drive the suite-wide geomean's
              # 50/50 application-vs-synthetic split. Application
              # benchmarks (XMPP today, network later) are declared
              # in meta.json's `applications` block; matching rows
              # carry `category: :application` + a family name so
              # their cells collapse into one cell per family before
              # the geomean folds them in.
              category: categorize(bname || bench_name, run.applications_meta),
              family: family_for(bname || bench_name, run.applications_meta),
              # Per-second sample series for application benchmarks
              # (XMPP cpu / mem / throughput today). Nil for synthetic
              # rows. Drives the stability page's drill-down sparkline.
              samples: Map.get(run.samples_by_bench, bname || bench_name)
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

  # Pull per-benchmark per-second sample arrays out of meta.json's
  # per-family blocks. XMPP today stores its raw CPU%, mem MB, and
  # throughput streams under `meta.xmpp.{cpu_pct,mem_mb,throughput}`
  # — keyed by the dashboard's full benchmark names so the row
  # builder doesn't need to know the per-family layout.
  defp samples_by_bench(meta) do
    xmpp = get(meta, "xmpp") || %{}

    %{}
    |> put_if_list("xmpp_cpu", get(xmpp, "cpu_pct"))
    |> put_if_list("xmpp_mem", get(xmpp, "mem_mb"))
    |> put_if_list("xmpp_speed", get(xmpp, "throughput"))
  end

  defp put_if_list(map, key, list) when is_list(list) and list != [], do: Map.put(map, key, list)
  defp put_if_list(map, _key, _), do: map

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

  @doc """
  Identify a scenario's `{benchmark, lang}`. The modern path emits
  names like `"Bounce/erlang"` — `parse_name/1` handles those. The
  legacy bundle path (OTP < 24, target-Elixir bundle compiled via
  mix) emits bare module names — `"awfy_bounce"` for Erlang and
  `"Awfy.Benchmarks.Bounce"` for Elixir (Benchee strips the
  internal `Elixir.` prefix when rendering). For those, look up
  which language's `module` in the per-bench meta matches the
  scenario name and pair it with the .benchee filename's base
  (bench_name) so legacy runs slot into the same per-lang series
  as modern runs.

  Exposed publicly because the scenario-naming convention is part
  of the write/read contract every measurement path has to honour —
  test/measure/scenario_names_test.exs pins it.
  """
  @spec identify_scenario(String.t(), String.t(), map()) :: {String.t() | nil, String.t() | nil}
  def identify_scenario(scenario_name, bench_name, languages) do
    case parse_name(scenario_name) do
      {bench, lang} when not is_nil(bench) and not is_nil(lang) ->
        {bench, lang}

      _ ->
        lang =
          Enum.find_value(languages, fn {lang, lang_meta} ->
            module = get(lang_meta, "module") || ""
            stripped = String.replace_prefix(module, "Elixir.", "")
            if scenario_name == module or scenario_name == stripped do
              lang
            end
          end)

        case lang do
          nil -> {nil, nil}
          _ -> {bench_name, lang}
        end
    end
  end

  # 6 decimal places preserves nanosecond resolution for
  # OtpBenchmarks-style sub-microsecond medians (12 ns rounds to
  # 0.000012 ms instead of 0.0). AWFY scenarios at the millisecond
  # scale lose nothing — the trailing zeros are noise.
  defp ns_to_ms(nil), do: nil
  defp ns_to_ms(ns) when is_number(ns), do: Float.round(ns / 1_000_000, 6)

  # Benchee's :percentiles map is keyed by integer percent (25, 50,
  # 75, 99). Older Benchee versions don't emit it at all — return
  # nil so the dashboard / stability page degrade gracefully on
  # legacy saves.
  defp get_percentile(stats, p) do
    case Map.get(stats, :percentiles) do
      %{^p => v} -> v
      _ -> nil
    end
  end

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

  # Labels are `<sha10>-test-<platform>-<arch>-<flavor>` per
  # Awfy.Measure.Helpers.run_dir/5. The trailing "-jit"/"-emu" is
  # the caller-supplied flavor, which matches what actually ran
  # on the target — see emu_flavor: above for why we override.
  defp flavor_from_label(label) when is_binary(label) do
    case String.split(label, "-") |> List.last() do
      "jit" -> "jit"
      "emu" -> "emu"
      _ -> nil
    end
  end

  defp flavor_from_label(_), do: nil

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
    # Group by `family` instead of `benchmark`: synthetic rows
    # already have family=benchmark_name (so the behaviour matches
    # the previous one-cell-per-benchmark shape), application rows
    # collapse multiple metric-cells into one family cell.
    label_by_family = index_by_family(label_rows)
    base_by_family = index_by_family(baseline_rows)

    intersection =
      MapSet.intersection(
        MapSet.new(Map.keys(label_by_family)),
        MapSet.new(Map.keys(base_by_family))
      )
      |> MapSet.to_list()
      |> Enum.sort()

    dropped =
      MapSet.union(
        MapSet.new(Map.keys(label_by_family)),
        MapSet.new(Map.keys(base_by_family))
      )
      |> MapSet.difference(MapSet.new(intersection))
      |> MapSet.to_list()
      |> Enum.sort()

    {app_families, synth_families} =
      Enum.split_with(intersection, fn fam ->
        category_for_family(fam, label_by_family, base_by_family) == :application
      end)

    g_app = bucket_geomean(app_families, label_by_family, base_by_family)
    g_synth = bucket_geomean(synth_families, label_by_family, base_by_family)

    # 50/50 weighting: combined geomean = geometric mean of the two
    # bucket geomeans (sqrt(G_app * G_synth)). If only one bucket has
    # data (no XMPP runs in this label, say) fall through to that
    # bucket's geomean directly so existing AWFY-only labels keep
    # producing the same number they always did.
    gm =
      case {g_app, g_synth} do
        {nil, nil} -> nil
        {nil, gs} -> gs
        {ga, nil} -> ga
        {ga, gs} -> :math.sqrt(ga * gs)
      end

    case gm do
      nil -> {nil, dropped}
      v -> {Float.round(v, 4), dropped}
    end
  end

  # Map family-name → median used for the ratio. Each family appears
  # once in the geomean regardless of how many cells it produced.
  defp index_by_family(rows) do
    rows
    |> Enum.filter(& &1.median_ms)
    |> Enum.group_by(& &1.family)
    |> Map.new(fn {fam, rs} -> {fam, group_median(rs)} end)
  end

  # Look up the family's category from either side's entry. Same
  # family name should map to the same category on both label and
  # baseline rows; we read whichever's present. Default :synthetic
  # so unknown families behave like AWFY benchmarks have always
  # behaved.
  defp category_for_family(family, label_by_family, base_by_family) do
    Map.get(label_by_family, family, %{}) |> Map.get(:category) ||
      Map.get(base_by_family, family, %{}) |> Map.get(:category) ||
      :synthetic
  end

  defp bucket_geomean([], _label, _base), do: nil

  defp bucket_geomean(families, label_by_family, base_by_family) do
    ratios =
      Enum.flat_map(families, fn fam ->
        l = Map.fetch!(label_by_family, fam).median
        b = Map.fetch!(base_by_family, fam).median

        if is_number(l) and l > 0 and is_number(b) and b > 0,
          do: [l / b],
          else: []
      end)

    case ratios do
      [] ->
        nil

      _ ->
        sum_log = Enum.reduce(ratios, 0.0, fn r, acc -> acc + :math.log(r) end)
        :math.exp(sum_log / length(ratios))
    end
  end

  @doc false
  def categorize(name, applications_meta) do
    if family_for(name, applications_meta) == name, do: :synthetic, else: :application
  end

  @doc false
  def family_for(name, applications_meta) do
    Enum.find_value(applications_meta || [], name, fn app ->
      fam = get(app, "name")

      if is_binary(fam) and String.starts_with?(name, fam <> "_") do
        fam
      end
    end)
  end

  # Three shapes feed into the family-keyed geomean index:
  #   * AWFY synthetic — one cell per (lang, benchmark). Pick the
  #     erlang cell so the cross-language table convention holds.
  #   * OtpBenchmarks synthetic multi-input — `input` set per row.
  #     family_geomean collapses across the inputs.
  #   * Application multi-metric — `category == :application`, no
  #     input set, multiple rows under the same family (one per
  #     metric: cpu_pct / mem_mb / throughput). family_geomean
  #     collapses across the metrics so the family contributes one
  #     cell to its bucket.
  # Returns a map carrying both the collapsed median and the row
  # category so geomean_ratio can route the family into the right
  # 50/50 bucket without re-reading row state.
  defp group_median(rows) do
    category = List.first(rows) |> Map.get(:category, :synthetic)

    median =
      cond do
        category == :application ->
          family_geomean(rows)

        Enum.any?(rows, fn r -> Map.get(r, :input) end) ->
          family_geomean(rows)

        true ->
          pick =
            Enum.find(rows, &(&1.lang == "erlang")) ||
              Enum.find(rows, &(&1.lang == "elixir")) ||
              List.first(rows)

          pick.median_ms
      end

    %{median: median, category: category}
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
