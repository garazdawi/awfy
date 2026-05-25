# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.Compare do
  @shortdoc "Generate the cross-version dashboard from results/*"
  @moduledoc """
  Read every saved measurement under `results/` and emit a static
  HTML dashboard:

    * `results/index.html` — suite-wide geomean trend with the
      same filter UI as per-benchmark pages.
    * `results/per-bench/<Bench>.html` — per-benchmark time-series
      chart, one per benchmark.

  Each page embeds the full dataset as JSON; charts and filter
  state are entirely client-side (Chart.js loaded from CDN). Filter
  selections persist to localStorage so subsequent visits remember
  the user's view.

  ## Usage

      mix awfy.compare                          # full dashboard from results/
      mix awfy.compare --benchmarks Bounce      # restrict to one benchmark page
      mix awfy.compare --labels v1,v2           # restrict to listed labels
      mix awfy.compare --baseline v1            # geomean ratio against v1
      mix awfy.compare --out somewhere          # output dir

  Open `results/index.html` in any browser when finished.
  """

  use Mix.Task

  # Dashboard CSS and JS live in priv/ as plain files so they get
  # treated as JS/CSS by the editor (and by stylelint / eslint /
  # prettier in CI), not as Elixir-heredoc strings. Read at compile
  # time and embedded into the generated HTML by `page_template/1` —
  # `@external_resource` makes mix recompile this module whenever
  # the priv files change.
  @dashboard_js_path Path.join([__DIR__, "..", "..", "..", "priv", "dashboard.js"])
  @dashboard_css_path Path.join([__DIR__, "..", "..", "..", "priv", "dashboard.css"])
  @external_resource @dashboard_js_path
  @external_resource @dashboard_css_path
  @dashboard_js File.read!(@dashboard_js_path)
  @dashboard_css File.read!(@dashboard_css_path)

  @switches [
    benchmarks: :string,
    labels: :string,
    baseline: :string,
    out: :string
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    out_dir = opts[:out] || "results"
    labels_filter = parse_csv(opts[:labels])
    bench_filter = parse_csv(opts[:benchmarks])

    data = Awfy.Compare.Data.load(out_dir, labels_filter)

    if data.runs == [] do
      Mix.raise("no runs found under #{out_dir}/")
    end

    bench_names =
      data.rows
      |> Enum.map(& &1.benchmark)
      |> Enum.uniq()
      |> filter_names(bench_filter)
      |> Enum.sort()

    if bench_names == [] do
      Mix.raise("no matching benchmarks in loaded runs")
    end

    File.mkdir_p!(Path.join(out_dir, "per-bench"))

    # Default: nil → dashboard JS picks each series's own earliest
    # data-point as the baseline. `--baseline LABEL` pins all series
    # to that one run, matching the original "regression vs X" use.
    baseline_label = opts[:baseline]

    Enum.each(bench_names, fn name ->
      page = render_per_bench(name, data, baseline_label)
      File.write!(Path.join([out_dir, "per-bench", "#{name}.html"]), page)
    end)

    File.write!(
      Path.join(out_dir, "index.html"),
      render_index(data, bench_names, baseline_label)
    )

    File.write!(
      Path.join(out_dir, "stability.html"),
      render_stability(data)
    )

    File.write!(
      Path.join(out_dir, "master.html"),
      render_master(data)
    )

    Mix.shell().info("Wrote #{out_dir}/index.html (#{length(bench_names)} benchmark pages, plus stability.html, master.html)")
  end

  defp parse_csv(nil), do: nil
  defp parse_csv(s), do: String.split(s, ",", trim: true)

  # The newest OTP major that has shipped a GA release. Read from the
  # first line of erlang/otp's `otp_versions.table` at build time —
  # that file is the canonical "latest tag" record on master. RC tags
  # of an upcoming major land on `maint-N` branches, not in this
  # table, so it cleanly distinguishes "released GA" from "in flight".
  #
  # Net failure (offline, GitHub unreachable) falls back to a
  # baseline value so the build still succeeds; bump @fallback when
  # the time-of-build value would otherwise lag a major. The cached
  # PAGE retrieves at build time only — the generated HTML is
  # static, no runtime fetch.
  @max_released_fallback 28

  defp max_released_major do
    url = "https://raw.githubusercontent.com/erlang/otp/master/otp_versions.table"

    with {:ok, body} <- fetch_text(url),
         [first_line | _] <- String.split(body, "\n", parts: 2),
         %{"major" => major} <- Regex.named_captures(~r/^OTP-(?<major>\d+)/, first_line) do
      String.to_integer(major)
    else
      _ ->
        Mix.shell().info("[compare] otp_versions.table unreachable, falling back to MAX_RELEASED_MAJOR=#{@max_released_fallback}")
        @max_released_fallback
    end
  end

  defp fetch_text(url) do
    # Shell out to curl rather than wire up :inets/:httpc — those
    # apps aren't loaded in the runner's release path and starting
    # them eagerly drags in a lot of incidental modules. curl is
    # already a hard dependency of bin/install-otp-source.sh and
    # the Dockerfile, so requiring it on the publish host is fine.
    case System.cmd("curl", ["-fsSL", "--max-time", "10", url], stderr_to_stdout: true) do
      {body, 0} -> {:ok, body}
      _ -> :error
    end
  end

  defp filter_names(names, nil), do: names

  defp filter_names(names, allow) do
    set = MapSet.new(allow)
    Enum.filter(names, &MapSet.member?(set, &1))
  end

  # =====================================================================
  # Per-benchmark page
  # =====================================================================
  defp render_per_bench(bench_name, data, baseline_label) do
    rows = Enum.filter(data.rows, &(&1.benchmark == bench_name))
    runs = data.runs

    warnings = collect_warnings_per_bench(bench_name, rows, runs)
    dataset_json = encode_dataset(rows, runs)

    page_template(%{
      title: "AWFY — #{bench_name}",
      heading: bench_name,
      subhead:
        "Median runtime in milliseconds for each run on the selected platform. Whiskers show ± 2σ.",
      breadcrumb: """
      <a href="../index.html">&larr; Suite</a> · #{bench_name}
      """,
      warnings_html: warnings_html(warnings),
      dataset_json: dataset_json,
      page_kind: "bench",
      bench_name: bench_name,
      baseline_label: baseline_label || ""
    })
  end

  # =====================================================================
  # Index page (suite-wide geomean trend + summary matrix)
  # =====================================================================
  defp render_index(data, bench_names, baseline_label) do
    rows =
      Enum.filter(data.rows, fn r -> r.benchmark in bench_names end)

    runs = data.runs

    warnings = collect_warnings_suite(rows, runs)
    dataset_json = encode_dataset(rows, runs)

    bench_links =
      bench_names
      |> Enum.map(fn n ->
        ~s(<li><a href="per-bench/#{n}.html">#{n}</a></li>)
      end)
      |> Enum.join("\n")

    page_template(%{
      title: "AWFY — Suite Dashboard",
      heading: "AWFY Suite — Cross-version Dashboard",
      subhead:
        "Geomean speedup across versions and platforms, with a per-benchmark snapshot below.",
      breadcrumb: "",
      warnings_html: warnings_html(warnings),
      dataset_json: dataset_json,
      page_kind: "suite",
      bench_name: "",
      baseline_label: baseline_label || "",
      snapshot_html: """
      <h3 class="snapshot-heading">Latest snapshot — per-benchmark across versions</h3>
      <p class="sub">Speedup (×) over the earliest recorded run for each (lang × machine_class × benchmark) baseline, evaluated at each major's latest patch. Bars above 1× are faster than baseline. Whiskers show ± 2σ. Bars with diagonal stripes and an "(emu)" legend suffix are emulator measurements shown in place of JIT, because that platform's BeamAsm JIT wasn't yet available at that version.</p>
      <div class="snapshot-majors" id="control-snapshot-majors"></div>
      <div class="chart-wrap snapshot"><canvas id="snapshot"></canvas></div>
      """,
      trend_heading_html: """
      <h3>Geomean speedup over versions</h3>
      <p class="sub">Geometric mean of <code>baseline_median / median</code>, higher = faster. <strong>Dashed</strong> segments are emulator data, <strong>solid</strong> are BeamAsm JIT.</p>
      <details class="explain">
        <summary>Explain this graph</summary>
        <p class="sub">Per-platform lines use emu data pre-Erlang/OTP 24 (BeamAsm JIT was added in 24) and JIT from 24 onwards, anchored at each platform's own earliest recorded run for every benchmark. The thicker <strong>all platforms</strong> line groups by Erlang/OTP function-release (e.g. <code>23.3</code>) so a coarser-grained Windows build (<code>OTP-23.3</code> installer) merges with a finer-grained linux/macos build (<code>OTP-23.3.4.20</code> patch tip), and includes any bucket where at least one platform contributed.</p>
        <p class="sub">Both Erlang and Elixir benchmark cells contribute to the geomean. Each Erlang/OTP major is paired with a specific Elixir version in the matrix (e.g. Erlang/OTP 25 → Elixir 1.17.3, Erlang/OTP 28 → Elixir 1.19.5), so Elixir's own compiler / stdlib evolution rides along in the numbers — it's not a pure Erlang/OTP runtime signal.</p>
      </details>
      """,
      benchmarks_list_html: """
      <h3>Benchmarks</h3>
      <ul class="bench-links">#{bench_links}</ul>
      """,
      extra_links_html: """
      <h3>More</h3>
      <ul class="bench-links">
        <li><a href="stability.html">Benchmark stability on master</a></li>
        <li><a href="master.html">Master timeline — every merge since OTP-29.0</a></li>
      </ul>
      """
    })
  end

  # =====================================================================
  # Master timeline — per-merge geomean speedup, on a timestamp axis.
  #
  # Number-exactness with the main page is the contract here: the
  # OTP-29.0 point on the master line must read the same speedup as
  # the OTP-29.0 point on the main suite chart. We get that by
  # mirroring `buildSuiteGeomeanSeries`' baseline computation server-
  # side — per-(lang, machine_class, benchmark) baseline anchored at
  # the earliest OTP version with the JIT-cutoff flavor fallback
  # (pre-24 emu → post-cutoff jit per platform), per-platform
  # geomean of per-bench ratios, all-platforms geomean of the per-
  # platform geomeans bucketed by commit. We then filter the visible
  # set to OTP-29.0 + master merges within the 3-month window so the
  # chart breathes around the recent activity without dragging the
  # decade-long historical baggage onto the page.
  # =====================================================================
  @master_window_days 90
  @jit_cutoff_by_platform %{
    "linux-x86_64" => 24,
    "linux-arm64" => 25,
    "macos-arm64" => 26,
    "windows-x86_64" => 24,
    "windows-arm64" => 24
  }

  defp render_master(data) do
    jit_rows = data.rows |> apply_jit_cutoff() |> fold_multi_input_families()
    baselines = build_baselines(jit_rows)
    per_platform = aggregate_per_platform(jit_rows, baselines)
    all_platforms = aggregate_all_platforms(per_platform)

    cutoff = DateTime.add(DateTime.utc_now(), -@master_window_days * 24 * 3600, :second)
    visible = Enum.filter(per_platform ++ all_platforms, &visible_on_master?(&1, cutoff))

    dataset_json = encode_dataset(visible, data.runs)

    page_template(%{
      title: "AWFY — Master timeline",
      heading: "Master timeline — last 3 months of master merges",
      subhead:
        "Geomean speedup vs OTP-20.3 (anchor matches the main suite chart), " <>
          "one line per platform plus a bold all-platforms aggregate. " <>
          "Higher = faster than the earliest measurement; OTP-29.0 reads " <>
          "the same value here as on the main dashboard.",
      breadcrumb: """
      <a href="index.html">&larr; Suite</a> · Master timeline
      """,
      warnings_html: "",
      dataset_json: dataset_json,
      page_kind: "master",
      bench_name: "",
      baseline_label: ""
    })
  end

  # Pre-cutoff emu, post-cutoff jit, per platform — mirrors the main
  # page's flavor-selection rule in `buildSuiteGeomeanSeries`. Without
  # this the OTP-29.0 master-page number wouldn't match the main page's
  # because the main page's baseline (typically OTP-20.3) is an emu
  # measurement.
  defp apply_jit_cutoff(rows) do
    Enum.filter(rows, fn r ->
      mc = machine_class(%{"arch" => r.arch})
      cutoff = Map.get(@jit_cutoff_by_platform, mc, 0)
      major = master_otp_major(r.otp)

      cond do
        r.otp in ["master", "maint"] -> r.emu_flavor == "jit"
        is_integer(major) and major >= cutoff -> r.emu_flavor == "jit"
        is_integer(major) -> r.emu_flavor == "emu"
        true -> r.emu_flavor == "jit"
      end
    end)
  end

  defp master_otp_major(otp) when is_binary(otp) do
    case Integer.parse(otp) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp master_otp_major(_), do: nil

  # Collapse OtpBenchmarks per-input rows into one family-level row
  # per (label, lang, mc, flavor, benchmark, otp) — mirrors
  # `foldMultiInputFamilies` in dashboard.js. Without the fold a 13-
  # input family like phash2 would contribute 13 cells to the
  # geomean against AWFY's 1-cell benchmarks, and the master line
  # would drift away from the main page's value.
  defp fold_multi_input_families(rows) do
    {with_input, without_input} = Enum.split_with(rows, fn r -> Map.get(r, :input) != nil end)

    synthetic =
      with_input
      |> Enum.group_by(fn r ->
        {r.label, r.lang, machine_class(%{"arch" => r.arch}), r.emu_flavor, r.benchmark,
         r.otp}
      end)
      |> Enum.map(fn {_k, group} ->
        positive = Enum.filter(group, &(is_number(&1.median_ms) and &1.median_ms > 0))

        case positive do
          [] ->
            nil

          _ ->
            template = hd(positive)
            gm = geomean(Enum.map(positive, & &1.median_ms))
            %{template | input: nil, median_ms: gm, stddev_ms: 0}
        end
      end)
      |> Enum.reject(&is_nil/1)

    without_input ++ synthetic
  end

  # Per-(lang, mc, benchmark) baseline = earliest OTP-version's median.
  # Tiebreak on timestamp. Mirrors `buildSuiteGeomeanSeries`' baseIdx
  # — same ordering rule (compareOtpVersions) so the resulting
  # baselines match exactly.
  defp build_baselines(rows) do
    rows
    |> Enum.filter(&(is_number(&1.median_ms) and &1.median_ms > 0))
    |> Enum.group_by(fn r ->
      {r.lang, machine_class(%{"arch" => r.arch}), r.benchmark}
    end)
    |> Map.new(fn {key, group} ->
      earliest =
        Enum.min_by(group, fn r ->
          {otp_sort_key(r.otp), r.timestamp || ""}
        end)

      {key, earliest.median_ms}
    end)
  end

  # Sort key for OTP versions. "20.3" → {0, 20, 3, 0, 0, 0}; "master"
  # / "maint" sort after everything numeric so they land at the right
  # edge. Mirrors `compareOtpVersions` in dashboard.js.
  defp otp_sort_key("master"), do: {2, 0, 0, 0, 0}
  defp otp_sort_key("maint"), do: {1, 0, 0, 0, 0}

  defp otp_sort_key(otp) when is_binary(otp) do
    parts =
      otp
      |> String.split(".")
      |> Enum.map(fn p ->
        case Integer.parse(p) do
          {n, _} -> n
          _ -> 0
        end
      end)

    {a, b, c, d} =
      case parts do
        [a, b, c, d | _] -> {a, b, c, d}
        [a, b, c] -> {a, b, c, 0}
        [a, b] -> {a, b, 0, 0}
        [a] -> {a, 0, 0, 0}
        _ -> {0, 0, 0, 0}
      end

    {0, a, b, c, d}
  end

  defp otp_sort_key(_), do: {0, 0, 0, 0, 0}

  # Per-(label, mc) aggregate ratio = geomean of per-benchmark
  # speedups vs the (lang, mc, benchmark) baseline. Encoded as
  # median_ms = 1.0 / aggregate_speedup so the JS buildSeries baseline
  # machinery (baseMs/median_ms) recovers the speedup as y at chart
  # time without master-specific JS branches.
  defp aggregate_per_platform(rows, baselines) do
    rows
    |> Enum.filter(&(is_number(&1.median_ms) and &1.median_ms > 0))
    |> Enum.group_by(fn r -> {r.label, machine_class(%{"arch" => r.arch})} end)
    |> Enum.map(fn {{label, mc}, group} ->
      template = hd(group)

      details =
        group
        |> Enum.map(fn r ->
          base = Map.get(baselines, {r.lang, mc, r.benchmark})

          ratio =
            if is_number(base) and base > 0 and is_number(r.median_ms) and r.median_ms > 0 do
              base / r.median_ms
            end

          %{
            "name" => r.benchmark,
            "median_ms" => r.median_ms,
            "speedup" => ratio,
            "lang" => r.lang,
            "input" => Map.get(r, :input)
          }
        end)
        |> Enum.sort_by(fn d -> {d["name"], d["input"] || ""} end)

      speedups =
        details
        |> Enum.map(& &1["speedup"])
        |> Enum.filter(&(is_number(&1) and &1 > 0))

      case speedups do
        [] ->
          nil

        _ ->
          agg = geomean(speedups)

          template
          |> Map.merge(%{
            benchmark: "aggregate",
            # Keep median_ms set (buildSeries needs a positive value to
            # accept the row) but the y the chart actually plots comes
            # from `master_y` below — the speedup vs the FULL-HISTORY
            # baseline (typically OTP-20.3). Without master_y the JS
            # would re-anchor on the earliest visible point (OTP-29.0
            # in our 3-month window), which would diverge from the
            # main page's number.
            median_ms: 1.0,
            machine_class_override: mc,
            stddev_ms: nil,
            min_ms: nil,
            max_ms: nil,
            p25_ms: nil,
            p75_ms: nil,
            p99_ms: nil,
            samples: nil,
            lang: nil,
            input: nil
          })
          |> Map.put(:otp_tag, otp_tag_for(template.otp))
          |> Map.put(:run_sha, extract_otp_sha10(label))
          |> Map.put(:bench_details, details)
          |> Map.put(:master_y, agg)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp otp_tag_for("master"), do: nil
  defp otp_tag_for("maint"), do: nil
  defp otp_tag_for(otp) when is_binary(otp), do: "OTP-" <> otp
  defp otp_tag_for(_), do: nil

  # All-platforms aggregate — at each OTP commit (= unique sha10),
  # geomean across the per-platform aggregates that measured the same
  # commit. Synthetic rows carry machine_class="all" and arch="all"
  # so buildSeries puts them in their own (thick) series.
  defp aggregate_all_platforms(per_platform_rows) do
    per_platform_rows
    |> Enum.group_by(fn r -> {extract_otp_sha10(r.label), r.timestamp, r.otp} end)
    |> Enum.map(fn {{sha10, ts, otp}, group} ->
      template = hd(group)
      # Per-platform master_y values feed the all-platforms geomean.
      per_platform_speedups = Enum.map(group, & &1.master_y)
      agg = geomean(per_platform_speedups)

      details =
        group
        |> Enum.map(fn r ->
          %{
            "name" => "geomean@" <> (r.machine_class_override || ""),
            "median_ms" => nil,
            "speedup" => r.master_y,
            "lang" => nil,
            "input" => nil
          }
        end)
        |> Enum.sort_by(& &1["name"])

      template
      |> Map.merge(%{
        label: "all-#{sha10}",
        machine_class_override: "all",
        arch: "all",
        timestamp: ts,
        otp: otp,
        median_ms: 1.0,
        stddev_ms: nil
      })
      |> Map.put(:bench_details, details)
      |> Map.put(:master_y, agg)
    end)
  end

  defp visible_on_master?(row, cutoff_dt) do
    cond do
      row.otp == "29.0" ->
        true

      row.otp == "master" ->
        case row.timestamp && DateTime.from_iso8601(row.timestamp) do
          {:ok, dt, _} -> DateTime.compare(dt, cutoff_dt) != :lt
          _ -> false
        end

      true ->
        false
    end
  end

  # Pluck the leading sha10 out of an AWFY run label. Label shape is
  # `<sha10>-test-<plat>-<arch>-<flavor>` (or with a `-dirty_<ts>`
  # suffix for locally-dirty trees); anything that doesn't match
  # returns the empty string, in which case the JS drill-down
  # falls back to "no commit SHA recorded for this run".
  defp extract_otp_sha10(label) when is_binary(label) do
    case Regex.run(~r/^([0-9a-f]{10})-/, label) do
      [_, sha] -> sha
      _ -> ""
    end
  end

  defp extract_otp_sha10(_), do: ""

  defp geomean(values) do
    nonzero = Enum.filter(values, &(is_number(&1) and &1 > 0))

    case nonzero do
      [] ->
        0.0

      _ ->
        sum_log = Enum.reduce(nonzero, 0.0, fn v, acc -> acc + :math.log(v) end)
        :math.exp(sum_log / length(nonzero))
    end
  end

  # =====================================================================
  # Stability page — coefficient-of-variation table for master runs
  # =====================================================================
  defp render_stability(data) do
    # Pick one row per (machine_class, emu_flavor, lang, input, bench)
    # bucket — latest timestamp wins so re-measurement supersedes a
    # stale row. Only consider master runs; older OTPs have their own
    # noise profile that mixes with hardware drift across the matrix.
    rows =
      data.rows
      |> Enum.filter(fn r ->
        r.otp == "master" and
          is_number(r.median_ms) and r.median_ms > 0 and
          is_number(r.stddev_ms) and r.stddev_ms >= 0
      end)
      |> Enum.group_by(fn r ->
        {machine_class(%{"arch" => r.arch}), r.emu_flavor, r.lang, Map.get(r, :input), r.benchmark}
      end)
      |> Enum.map(fn {_k, rs} ->
        Enum.max_by(rs, & &1.timestamp)
      end)

    enriched =
      rows
      |> Enum.map(fn r ->
        cv = r.stddev_ms / r.median_ms * 100

        # IQR/median %: robust spread, ignores tails. Rows missing
        # percentiles (legacy Benchee saves) get nil, which sorts
        # last under :desc.
        iqr_pct =
          case {Map.get(r, :p25_ms), Map.get(r, :p75_ms)} do
            {p25, p75} when is_number(p25) and is_number(p75) ->
              (p75 - p25) / r.median_ms * 100

            _ ->
              nil
          end

        Map.merge(r, %{cv_pct: cv, iqr_pct: iqr_pct, group: scenario_group(r)})
      end)
      # Primary sort: IQR/median % desc (robust spread).
      # Secondary: CV% desc as a tiebreaker for legacy rows without
      # percentiles. nil sorts last on Erlang term order so legacy
      # rows fall to the bottom on the first key.
      |> Enum.sort_by(fn r -> {-(r.iqr_pct || -1.0), -r.cv_pct} end)

    platforms = enriched |> Enum.map(&machine_class(%{"arch" => &1.arch})) |> Enum.uniq() |> Enum.sort()
    flavors = enriched |> Enum.map(& &1.emu_flavor) |> Enum.uniq() |> Enum.sort()
    groups = enriched |> Enum.map(& &1.group) |> Enum.uniq() |> Enum.sort()

    table_rows =
      enriched
      |> Enum.with_index(1)
      |> Enum.map(fn {r, rank} ->
        scenario =
          case Map.get(r, :input) do
            nil -> r.benchmark
            "" -> r.benchmark
            input -> "#{r.benchmark}/#{input}"
          end

        # Tier the IQR/median % cell so visual scan tracks
        # magnitudes: <5 % calm, 5–20 % watch, >20 % noisy. Tuned
        # to where real microbenchmark spread starts (vs the
        # clock-floor lower bound). CV% is shown alongside but no
        # longer colour-tiered — it gets dominated by single outliers
        # on million-sample rows.
        iqr_class =
          cond do
            r.iqr_pct == nil -> "stability-unknown"
            r.iqr_pct >= 20.0 -> "stability-bad"
            r.iqr_pct >= 5.0 -> "stability-warn"
            true -> "stability-good"
          end

        iqr_cell =
          case r.iqr_pct do
            nil -> "—"
            v -> "#{:io_lib.format(~c"~.2f", [v]) |> List.to_string()} %"
          end

        mc = machine_class(%{"arch" => r.arch})

        # Inline per-row distribution stats so the click handler can
        # draw the box plot from data attributes (no second fetch).
        # Older runs without percentiles fall through to empty
        # strings and the click handler hides the drill-down row.
        dist =
          [
            {"min", r.min_ms},
            {"p25", r.p25_ms},
            {"median", r.median_ms},
            {"p75", r.p75_ms},
            {"p99", r.p99_ms},
            {"max", r.max_ms},
            {"mean", r.mean_ms},
            {"stddev", r.stddev_ms}
          ]
          |> Enum.map(fn {k, v} -> ~s|data-#{k}="#{v || ""}"| end)
          |> Enum.join(" ")

        spark = sparkline_attrs(r)

        ~s"""
        <tr class="stability-row" data-platform="#{mc}" data-flavor="#{r.emu_flavor}" data-group="#{r.group}" #{dist} #{spark}>
          <td class="rank">#{rank}</td>
          <td>#{scenario}</td>
          <td>#{r.lang || "—"}</td>
          <td>#{mc}</td>
          <td>#{r.emu_flavor}</td>
          <td class="num">#{format_ms(r.median_ms)}</td>
          <td class="num #{iqr_class}">#{iqr_cell}</td>
          <td class="num">#{:io_lib.format(~c"~.2f", [r.cv_pct]) |> List.to_string()} %</td>
          <td class="num">#{r.samples_n || "—"}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    filter_controls = stability_filter_controls(platforms, flavors, groups)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>AWFY — Benchmark stability on master</title>
    <style>
    #{@dashboard_css}
    table.stability {
      border-collapse: collapse;
      width: 100%;
      font-size: 0.9rem;
    }
    table.stability th, table.stability td {
      padding: 0.4rem 0.6rem;
      border-bottom: 1px solid var(--er-border);
      text-align: left;
    }
    table.stability th { background: var(--er-tint); font-weight: 600; }
    table.stability th[title] { text-decoration: underline dotted var(--er-muted); text-underline-offset: 3px; cursor: help; }
    table.stability td.num { text-align: right; font-variant-numeric: tabular-nums; font-family: var(--mono); }
    table.stability td.rank { color: var(--er-muted); width: 3em; text-align: right; }
    .stability-good { color: var(--er-good); }
    .stability-warn { color: #b58900; }
    .stability-bad { color: var(--er-bad); font-weight: 600; }
    .stability-unknown { color: var(--er-muted); }
    .stability-filters { display: flex; flex-wrap: wrap; gap: 1.25rem; padding: 0.6rem 0.85rem; background: var(--er-tint); border: 1px solid var(--er-border); border-radius: 4px; font-size: 0.9rem; align-items: flex-start; margin-bottom: 1rem; }
    .stability-filters .group { display: flex; flex-direction: column; gap: 0.2rem; }
    .stability-filters b { font-weight: 600; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--er-muted); }
    .stability-filters .opts { display: flex; flex-wrap: wrap; column-gap: 0.85rem; row-gap: 0.2rem; }
    .stability-filters label { cursor: pointer; user-select: none; display: inline-flex; gap: 0.25rem; align-items: center; }
    .stability-row-count { color: var(--er-muted); font-size: 0.85rem; margin-bottom: 0.4rem; }
    table.stability tr.stability-row { cursor: pointer; }
    table.stability tr.stability-row:hover { background: var(--er-tint); }
    table.stability tr.stability-detail td { background: var(--er-tint); padding: 0.7rem 1rem; border-bottom: 1px solid var(--er-border); }
    .boxplot-wrap { display: flex; gap: 1.5rem; align-items: center; flex-wrap: wrap; }
    .boxplot-wrap dl { margin: 0; display: grid; grid-template-columns: max-content max-content; gap: 0.1rem 0.85rem; font-size: 0.8rem; }
    .boxplot-wrap dt { color: var(--er-muted); }
    .boxplot-wrap dd { margin: 0; font-family: var(--mono); font-variant-numeric: tabular-nums; }
    .spark-caption { font-size: 0.78rem; color: var(--er-muted); margin: 0.15rem 0 0.3rem 0; }
    </style>
    </head>
    <body>
    <header class="site-header">
      <span class="brand"><a href="../">AWFY · Erlang/OTP</a></span>
      <span class="breadcrumb"><a href="index.html">&larr; Suite</a> · Stability</span>
    </header>
    <h1>Benchmark stability on master</h1>
    <p class="sub">Primary sort: <strong>IQR / median %</strong> — (p75 − p25) / median, the spread of the middle half of samples. Robust to tail outliers, so a single GC-pause or scheduler-preemption hit doesn't dominate. CV% (σ / median) is shown as a secondary column for tail-spike visibility — those two metrics can disagree, e.g. a scenario with 1M samples and one bad sample reads as 8000 % CV but &lt; 100 % IQR/median because 99 % of samples cluster tightly.</p>
    <p class="sub">IQR / median thresholds: <span class="stability-good">&lt; 5 %</span> calm, <span class="stability-warn">5 – 20 %</span> watch, <span class="stability-bad">&gt; 20 %</span> noisy. Click any row for a box-plot breakdown.</p>

    #{filter_controls}
    <div class="stability-row-count" id="stability-row-count"></div>

    <table class="stability">
      <thead>
        <tr>
          <th>#</th>
          <th>scenario</th>
          <th>lang</th>
          <th>platform</th>
          <th>flavor</th>
          <th title="Median sample run time. Benchee reports times in nanoseconds; the dashboard renders milliseconds throughout.">median (ms)</th>
          <th title="(p75 − p25) ÷ median × 100 %. The spread of the middle half of samples relative to the median. Robust to tail outliers — one bad scheduling spike won't dominate this number — so it reflects the typical sample-to-sample variance.">IQR / median</th>
          <th title="Coefficient of variation: σ ÷ median × 100 %. Tail-aware: a single 2 ms outlier on a 42 ns median pushes this to 1000s of percent, even when 99 % of samples are tightly clustered. Useful for spotting tail-latency issues but a poor primary stability metric for million-sample rows.">CV (σ / median)</th>
          <th title="Number of times Benchee invoked the function during the timing window. Driven by the workload's per-call duration (faster benchmark → more samples in the same time budget).">samples</th>
        </tr>
      </thead>
      <tbody>
    #{table_rows}
      </tbody>
    </table>

    <script>
    (function () {
      const KEY = "awfy.stability.filters";
      const root = document.querySelector(".stability-filters");
      const tbody = document.querySelector("table.stability tbody");
      const counter = document.getElementById("stability-row-count");
      if (!root || !tbody) return;

      const load = () => {
        try { return JSON.parse(localStorage.getItem(KEY)) || {}; }
        catch (_) { return {}; }
      };
      const save = (s) => {
        try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (_) {}
      };

      const persisted = load();
      // First visit: every checkbox starts checked (show all rows).
      // Persisted state, when present, controls visibility per axis.
      root.querySelectorAll('input[type="checkbox"]').forEach(cb => {
        const axis = cb.dataset.axis;
        const val = cb.value;
        if (persisted[axis] && Array.isArray(persisted[axis])) {
          cb.checked = persisted[axis].includes(val);
        }
      });

      const apply = () => {
        const sel = { platform: new Set(), flavor: new Set(), group: new Set() };
        root.querySelectorAll('input[type="checkbox"]:checked').forEach(cb => {
          sel[cb.dataset.axis].add(cb.value);
        });
        let visible = 0;
        const rows = tbody.querySelectorAll("tr");
        rows.forEach(tr => {
          const show =
            sel.platform.has(tr.dataset.platform) &&
            sel.flavor.has(tr.dataset.flavor) &&
            sel.group.has(tr.dataset.group);
          tr.style.display = show ? "" : "none";
          if (show) visible++;
        });
        counter.textContent = visible + " of " + rows.length + " scenarios shown";
      };

      root.addEventListener("change", () => {
        const out = { platform: [], flavor: [], group: [] };
        root.querySelectorAll('input[type="checkbox"]:checked').forEach(cb => {
          out[cb.dataset.axis].push(cb.value);
        });
        save(out);
        apply();
      });

      apply();

      // -- Click-to-expand box plot ---------------------------------
      // Per-row drill-down: clicking a stability-row toggles a detail
      // row immediately below with min / p25 / median / p75 / p99 /
      // max as a horizontal box plot, plus the numeric values.
      // Distribution data comes from data-* attributes baked into
      // each row server-side; older runs that lack percentiles render
      // a "no distribution data" line.
      const fmtMs = (n) => {
        if (n === null || isNaN(n)) return "—";
        if (n >= 1) return n.toFixed(3) + " ms";
        if (n >= 0.001) return (n * 1000).toFixed(2) + " µs";
        return (n * 1_000_000).toFixed(2) + " ns";
      };
      const readNum = (el, key) => {
        const v = el.dataset[key];
        if (v === undefined || v === "") return null;
        const n = parseFloat(v);
        return isNaN(n) ? null : n;
      };
      const readSamples = (el) => {
        const raw = el.dataset.samples;
        if (!raw) return null;
        const out = [];
        for (const tok of raw.split(",")) {
          if (tok === "") continue;
          const n = parseFloat(tok);
          if (!isNaN(n)) out.push(n);
        }
        return out.length ? out : null;
      };
      // Per-second time series sparkline for application benchmarks
      // (XMPP cpu / mem / throughput). Box-plot is misleading for
      // these because the samples aren't independent draws — they
      // trace a ramp-up / steady-state shape and one outlier at
      // second 0 isn't comparable to one at second 30. The sparkline
      // shows the shape directly so a click can answer "did this
      // regress on average, or did it crash mid-run?".
      const fmtUnit = (n, unit) => {
        if (n === null || isNaN(n)) return "—";
        if (unit === "msg/s") return n.toFixed(0) + " " + unit;
        if (unit === "%") return n.toFixed(1) + " " + unit;
        if (unit === "MB") return n.toFixed(0) + " " + unit;
        return n.toFixed(2);
      };
      const sparklineSVG = (samples, unit) => {
        if (!samples || samples.length < 2) {
          return '<em style="color: var(--er-muted)">Not enough samples for a sparkline.</em>';
        }
        const w = 480, h = 70, padL = 36, padR = 8, padT = 8, padB = 18;
        const innerW = w - padL - padR, innerH = h - padT - padB;
        const lo = Math.min(...samples);
        const hi = Math.max(...samples);
        const range = Math.max(hi - lo, 1e-12);
        const x = (i) => padL + (i / (samples.length - 1)) * innerW;
        const y = (v) => padT + (1 - (v - lo) / range) * innerH;
        let d = "M" + x(0) + "," + y(samples[0]);
        for (let i = 1; i < samples.length; i++) d += " L" + x(i) + "," + y(samples[i]);
        const sum = samples.reduce((a, b) => a + b, 0);
        const mean = sum / samples.length;
        const my = y(mean);
        const parts = [];
        // y-axis tick labels (min / max)
        parts.push('<text x="' + (padL - 4) + '" y="' + (padT + 4) + '" font-size="9" fill="#666" text-anchor="end">' + fmtUnit(hi, unit) + '</text>');
        parts.push('<text x="' + (padL - 4) + '" y="' + (padT + innerH) + '" font-size="9" fill="#666" text-anchor="end">' + fmtUnit(lo, unit) + '</text>');
        // x-axis: seconds 0 and N-1
        parts.push('<text x="' + padL + '" y="' + (h - 4) + '" font-size="9" fill="#666" text-anchor="start">0 s</text>');
        parts.push('<text x="' + (w - padR) + '" y="' + (h - 4) + '" font-size="9" fill="#666" text-anchor="end">' + (samples.length - 1) + ' s</text>');
        // mean line
        parts.push('<line x1="' + padL + '" y1="' + my + '" x2="' + (w - padR) + '" y2="' + my + '" stroke="#a2003e" stroke-dasharray="2,3" stroke-width="1" opacity="0.6"/>');
        parts.push('<text x="' + (w - padR) + '" y="' + (my - 2) + '" font-size="9" fill="#a2003e" text-anchor="end">mean ' + fmtUnit(mean, unit) + '</text>');
        // series line
        parts.push('<path d="' + d + '" fill="none" stroke="#a2003e" stroke-width="1.5"/>');
        return '<svg width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '" role="img" aria-label="per-second samples">' + parts.join("") + '</svg>';
      };
      const boxplotSVG = (min, p25, med, p75, p99, max) => {
        // Layout in a 480 × 60 viewbox. Use min/max as the scale so
        // the whole spread is visible; pin at the lower bound 0 if
        // min is non-negative (avoids the box drifting away from the
        // axis on very-small-variance runs).
        const lo = (min !== null && min > 0) ? min * 0.95 : 0;
        const hi = (max !== null) ? max * 1.02 : (p99 || med || 1);
        const range = Math.max(hi - lo, 1e-12);
        const x = (v) => 30 + ((v - lo) / range) * 420;
        const yMid = 28, boxTop = 14, boxBot = 42;
        const parts = [];
        // axis
        parts.push('<line x1="30" y1="55" x2="450" y2="55" stroke="#bbb" stroke-width="1"/>');
        // ticks: min / median / max
        const tick = (v, label) => {
          if (v === null) return "";
          const tx = x(v);
          return '<line x1="' + tx + '" y1="55" x2="' + tx + '" y2="58" stroke="#888"/>' +
                 '<text x="' + tx + '" y="58" font-size="9" fill="#666" text-anchor="middle" dy="0.9em">' + label + '</text>';
        };
        parts.push(tick(min, fmtMs(min)));
        parts.push(tick(med, fmtMs(med)));
        parts.push(tick(max, fmtMs(max)));
        // whiskers: min — p25, p75 — max
        if (min !== null && p25 !== null) {
          parts.push('<line x1="' + x(min) + '" y1="' + yMid + '" x2="' + x(p25) + '" y2="' + yMid + '" stroke="#888" stroke-width="1"/>');
          parts.push('<line x1="' + x(min) + '" y1="' + (yMid - 6) + '" x2="' + x(min) + '" y2="' + (yMid + 6) + '" stroke="#888"/>');
        }
        if (max !== null && p75 !== null) {
          parts.push('<line x1="' + x(p75) + '" y1="' + yMid + '" x2="' + x(max) + '" y2="' + yMid + '" stroke="#888" stroke-width="1"/>');
          parts.push('<line x1="' + x(max) + '" y1="' + (yMid - 6) + '" x2="' + x(max) + '" y2="' + (yMid + 6) + '" stroke="#888"/>');
        }
        // box: p25 — p75
        if (p25 !== null && p75 !== null) {
          parts.push('<rect x="' + x(p25) + '" y="' + boxTop + '" width="' + (x(p75) - x(p25)) + '" height="' + (boxBot - boxTop) + '" fill="#a2003e22" stroke="#a2003e" stroke-width="1.5"/>');
        }
        // median line
        if (med !== null) {
          parts.push('<line x1="' + x(med) + '" y1="' + boxTop + '" x2="' + x(med) + '" y2="' + boxBot + '" stroke="#a2003e" stroke-width="2"/>');
        }
        // p99 dot
        if (p99 !== null) {
          parts.push('<circle cx="' + x(p99) + '" cy="' + yMid + '" r="3" fill="#a2003e"/>');
        }
        return '<svg width="480" height="70" viewBox="0 0 480 70" role="img" aria-label="distribution">' + parts.join("") + '</svg>';
      };

      const buildDetail = (row) => {
        const tr = document.createElement("tr");
        tr.className = "stability-detail";
        const td = document.createElement("td");
        td.colSpan = 9;

        const samples = readSamples(row);
        if (samples) {
          // Per-second time series — show the shape rather than a
          // box plot. Box-plot quantiles aren't meaningful for these
          // because the samples trace a ramp/steady-state curve.
          const unit = row.dataset.samplesUnit || "";
          const sum = samples.reduce((a, b) => a + b, 0);
          const mean = sum / samples.length;
          const sortedS = samples.slice().sort((a, b) => a - b);
          const sMin = sortedS[0], sMax = sortedS[sortedS.length - 1];
          const sMed = sortedS[Math.floor(sortedS.length / 2)];
          td.innerHTML =
            '<p class="spark-caption">Per-second samples across the measurement window. ' +
              'Look for trends (drift across the run) or step-changes (mid-run failure).</p>' +
            '<div class="boxplot-wrap">' +
              sparklineSVG(samples, unit) +
              '<dl>' +
                '<dt>samples</dt><dd>' + samples.length + '</dd>' +
                '<dt>min</dt><dd>' + fmtUnit(sMin, unit) + '</dd>' +
                '<dt>median</dt><dd>' + fmtUnit(sMed, unit) + '</dd>' +
                '<dt>mean</dt><dd>' + fmtUnit(mean, unit) + '</dd>' +
                '<dt>max</dt><dd>' + fmtUnit(sMax, unit) + '</dd>' +
              '</dl>' +
            '</div>';
          tr.appendChild(td);
          return tr;
        }

        const min = readNum(row, "min");
        const p25 = readNum(row, "p25");
        const med = readNum(row, "median");
        const p75 = readNum(row, "p75");
        const p99 = readNum(row, "p99");
        const max = readNum(row, "max");
        const mean = readNum(row, "mean");
        const stddev = readNum(row, "stddev");
        if (med === null || p25 === null || p75 === null) {
          td.innerHTML = '<em style="color: var(--er-muted)">No distribution data — older Benchee save format. Re-run on the latest measure to populate percentiles.</em>';
        } else {
          td.innerHTML =
            '<div class="boxplot-wrap">' +
              boxplotSVG(min, p25, med, p75, p99, max) +
              '<dl>' +
                '<dt>min</dt><dd>' + fmtMs(min) + '</dd>' +
                '<dt>p25</dt><dd>' + fmtMs(p25) + '</dd>' +
                '<dt>median</dt><dd>' + fmtMs(med) + '</dd>' +
                '<dt>mean</dt><dd>' + fmtMs(mean) + '</dd>' +
                '<dt>p75</dt><dd>' + fmtMs(p75) + '</dd>' +
                '<dt>p99</dt><dd>' + fmtMs(p99) + '</dd>' +
                '<dt>max</dt><dd>' + fmtMs(max) + '</dd>' +
                '<dt>σ</dt><dd>' + fmtMs(stddev) + '</dd>' +
              '</dl>' +
            '</div>';
        }
        tr.appendChild(td);
        return tr;
      };

      tbody.addEventListener("click", (e) => {
        const row = e.target.closest("tr.stability-row");
        if (!row) return;
        const next = row.nextElementSibling;
        if (next && next.classList.contains("stability-detail")) {
          next.remove();
          return;
        }
        const detail = buildDetail(row);
        row.parentNode.insertBefore(detail, row.nextSibling);
      });
    })();
    </script>
    </body>
    </html>
    """
  end

  # Bucket each row into a "scenario group" for the stability filter:
  # the AWFY cross-language suite is one group regardless of how many
  # benchmarks it ships, and every OtpBenchmarks family (maps, ets,
  # phash2, …) is its own group keyed by the benchmark name. AWFY rows
  # are recognised by having a populated `:lang` (erlang / elixir) and
  # no `:input`; OtpBenchmarks rows have `:input` set and `:lang` nil.
  # Encode the per-second sample series on the row so the drill-down
  # click handler can draw a sparkline without a second fetch. The
  # unit label is split out from the values so the y-axis tick can
  # be formatted client-side (CPU %, mem MB, msg/s) without the JS
  # having to special-case benchmark names. Empty for synthetic rows
  # — sparkline only renders when samples are present.
  defp sparkline_attrs(%{samples: samples, benchmark: bench}) when is_list(samples) and samples != [] do
    csv =
      samples
      |> Enum.map(fn
        v when is_integer(v) -> Integer.to_string(v)
        v when is_float(v) -> :erlang.float_to_binary(v, decimals: 3)
        _ -> ""
      end)
      |> Enum.join(",")

    unit = samples_unit_for(bench)
    ~s|data-samples="#{csv}" data-samples-unit="#{unit}"|
  end

  defp sparkline_attrs(_), do: ""

  defp samples_unit_for("xmpp_cpu"), do: "%"
  defp samples_unit_for("xmpp_mem"), do: "MB"
  defp samples_unit_for("xmpp_speed"), do: "msg/s"
  defp samples_unit_for(_), do: ""

  defp scenario_group(r) do
    case {Map.get(r, :category), r.lang, Map.get(r, :input)} do
      # Application benchmarks (XMPP today, network later) come in
      # one row per metric under a shared family — keep them in a
      # group of their own (the family name) so the stability page's
      # filter can show / hide them as a unit, instead of mixing
      # them into the synthetic "AWFY" bucket which threw the user
      # off when the cells appeared mid-ranking.
      {:application, _, _} -> Map.get(r, :family) || r.benchmark
      {_, lang, nil} when lang in ["erlang", "elixir"] -> "AWFY"
      _ -> r.benchmark
    end
  end

  defp stability_filter_controls(platforms, flavors, groups) do
    render_group = fn axis, label, values ->
      opts =
        values
        |> Enum.map(fn v ->
          ~s|<label><input type="checkbox" data-axis="#{axis}" value="#{v}" checked> #{v}</label>|
        end)
        |> Enum.join("\n")

      ~s"""
      <div class="group">
        <b>#{label}</b>
        <div class="opts">
      #{opts}
        </div>
      </div>
      """
    end

    """
    <div class="stability-filters">
    #{render_group.("platform", "Platform", platforms)}
    #{render_group.("flavor", "Flavor", flavors)}
    #{render_group.("group", "Scenario group", groups)}
    </div>
    """
  end

  defp format_ms(ms) when is_number(ms) do
    # 4 significant figures: AWFY medians span ms→sec, OtpBenchmarks
    # span ns→µs. ~r format keeps the precision without trailing zeros.
    cond do
      ms == 0 -> "0"
      ms >= 1 -> :erlang.float_to_binary(ms * 1.0, decimals: 3)
      true -> :erlang.float_to_binary(ms * 1.0, decimals: 6)
    end
  end

  defp format_ms(_), do: "—"

  # =====================================================================
  # Warnings (Q4, Q5, Q4b mismatches)
  # =====================================================================
  defp collect_warnings_per_bench(_bench_name, rows, _runs) do
    warnings = []

    iters =
      rows
      |> Enum.map(& &1.inner_iter)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    warnings =
      case iters do
        [_] -> warnings
        [] -> warnings
        many -> ["inner_iter differs across runs: #{inspect(many)}" | warnings]
      end

    shas =
      rows
      |> Enum.map(&{&1.lang, &1.source_sha256})
      |> Enum.reject(fn {_, s} -> s in [nil, ""] end)
      |> Enum.uniq()

    sha_by_lang = Enum.group_by(shas, &elem(&1, 0), &elem(&1, 1))

    warnings =
      Enum.reduce(sha_by_lang, warnings, fn {lang, list}, acc ->
        case Enum.uniq(list) do
          [_] -> acc
          many -> ["benchmark source changed (#{lang}): #{length(many)} distinct hashes" | acc]
        end
      end)

    Enum.reverse(warnings)
  end

  defp collect_warnings_suite(_rows, _runs) do
    # The cross-platform dashboard intentionally shows multiple machines
    # and both emu flavors as separate series. Warning about either
    # being "different" is just noise — the chart legend already says so.
    []
  end

  defp warnings_html([]), do: ""

  defp warnings_html(list) do
    items = Enum.map(list, fn w -> "<li>#{w |> to_string() |> escape_html()}</li>" end)
    "<div class=\"warnings\"><strong>Notes:</strong><ul>#{Enum.join(items, "")}</ul></div>"
  end

  defp escape_html(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Collapse the GNU machine triple to a stable, human-friendly bucket
  # the dashboard groups series by. Hostnames on CI runners are
  # ephemeral (different every job), so series-keyed by hostname end
  # up with a single data-point each — the chart shows nothing.
  #
  #   "x86_64-pc-linux-gnu"        -> "linux-x86_64"
  #   "aarch64-apple-darwin24.6.0" -> "macos-arm64"
  #   "x86_64-w64-mingw32"         -> "windows-x86_64"
  defp machine_class(%{"arch" => arch}) when is_binary(arch) do
    # Older OTP Windows reports arch as a bare "win32"; modern OTP
    # reports the full GNU triple "x86_64-pc-windows". Normalize both
    # to the same bucket so series collapse correctly.
    if arch in ["win32", "win64"] or String.starts_with?(arch, "win") do
      "windows-x86_64"
    else
      cpu =
        cond do
          String.starts_with?(arch, "x86_64") -> "x86_64"
          String.starts_with?(arch, "aarch64") -> "arm64"
          String.starts_with?(arch, "arm64") -> "arm64"
          true -> arch |> String.split("-") |> hd()
        end

      os =
        cond do
          String.contains?(arch, "linux") -> "linux"
          String.contains?(arch, "darwin") -> "macos"
          String.contains?(arch, "mingw") or String.contains?(arch, "windows") -> "windows"
          String.contains?(arch, "freebsd") -> "freebsd"
          true -> "unknown"
        end

      "#{os}-#{cpu}"
    end
  end

  defp machine_class(_), do: "unknown"

  # =====================================================================
  # Dataset encoding
  # =====================================================================
  defp encode_dataset(rows, runs) do
    runs_summary =
      Enum.map(runs, fn r ->
        %{
          "label" => r.label,
          "timestamp" => r.timestamp,
          "otp" => r.otp,
          "elixir" => r.elixir,
          "hostname" => r.machine["hostname"],
          "cpu" => r.machine["cpu"],
          "arch" => r.machine["arch"],
          "os" => r.machine["os"],
          "cores" => r.machine["cores"],
          "machine_class" => machine_class(r.machine),
          "emu_flavor" => r.runtime["emu_flavor"],
          "schedulers_online" => r.runtime["schedulers_online"],
          "wordsize" => r.runtime["wordsize"],
          "c_compiler_used" => r.runtime["c_compiler_used"],
          "build_flags" => r.config["build_flags"]
        }
      end)

    rows_json =
      Enum.map(rows, fn r ->
        %{
          "label" => r.label,
          "timestamp" => r.timestamp,
          "otp" => r.otp,
          "elixir" => r.elixir,
          "hostname" => r.hostname,
          "cpu" => r.cpu,
          "arch" => r.arch,
          "machine_class" => Map.get(r, :machine_class_override) || machine_class(%{"arch" => r.arch}),
          "emu_flavor" => r.emu_flavor,
          "lang" => r.lang,
          "input" => Map.get(r, :input),
          "benchmark" => r.benchmark,
          "median_ms" => r.median_ms,
          "mean_ms" => r.mean_ms,
          "stddev_ms" => r.stddev_ms,
          "min_ms" => Map.get(r, :min_ms),
          "max_ms" => Map.get(r, :max_ms),
          "p25_ms" => Map.get(r, :p25_ms),
          "p75_ms" => Map.get(r, :p75_ms),
          "p99_ms" => Map.get(r, :p99_ms),
          "samples_n" => r.samples_n,
          "inner_iter" => r.inner_iter,
          "source_sha256" => r.source_sha256,
          "verified" => r.verified,
          # Per-second sample series for application benchmarks (XMPP
          # cpu / mem / throughput). Carried into the chart so an
          # onClick on the per-bench page can pop up a sparkline of
          # the clicked run alongside others — letting a user
          # eyeball master vs 28.5's CPU shape on the same page.
          "samples" => Map.get(r, :samples),
          "samples_unit" => samples_unit_for(r.benchmark),
          # Master-timeline drill-down fields. Populated by
          # render_master/1's aggregate_per_series via
          # filter_for_master_view; nil for non-master-page rows.
          # * otp_tag — `"OTP-X.Y.Z"` for tagged maint-tip points so
          #   the chart can paint the tag name above the dot; nil for
          #   master merges (those are identified by run_sha instead).
          # * run_sha — OTP commit SHA from meta.json.git.sha. Used
          #   by the click drill-down to look up the PR via
          #   `api.github.com/repos/erlang/otp/commits/<sha>/pulls`.
          # * bench_details — un-aggregated per-benchmark medians for
          #   the run, so the drill-down can show "phash2 is 4.1x
          #   faster, Bounce is 1.3x faster, …" without re-loading.
          "otp_tag" => Map.get(r, :otp_tag),
          "run_sha" => Map.get(r, :run_sha),
          "bench_details" => Map.get(r, :bench_details),
          # Master-timeline only: the actual y to plot, ratioed
          # against the FULL-HISTORY baseline (typically OTP-20.3)
          # so the OTP-29.0 number here equals the OTP-29.0 number
          # on the main suite chart. buildSeries' default
          # baseMs/median_ms machinery would re-anchor on the
          # earliest VISIBLE point, which is OTP-29.0 in our
          # 3-month window — yielding y ~ 1.0× there instead of
          # the historical 5.x× the main page shows. We bypass
          # that with this explicit y.
          "master_y" => Map.get(r, :master_y)
        }
      end)

    payload = %{
      "runs" => runs_summary,
      "rows" => rows_json
    }

    Jason.encode!(payload)
  end

  # =====================================================================
  # Page template
  # =====================================================================
  defp page_template(ctx) do
    ~s"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>#{ctx.title}</title>
      <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.6/dist/chart.umd.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/chartjs-chart-error-bars@4"></script>
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@400;500;600;700&display=swap" rel="stylesheet">
      <style>
    #{@dashboard_css}
      </style>
    </head>
    <body>
      <header class="site-header">
        <span class="brand"><a href="../">AWFY · Erlang/OTP</a></span>
        <span class="breadcrumb">#{ctx.breadcrumb}</span>
      </header>
      <h1>#{ctx.heading}</h1>
      <p class="sub">#{ctx.subhead}</p>

      <div id="headline" class="headline headline-card"></div>

      #{ctx.warnings_html}

      #{if ctx.page_kind == "suite", do: Map.get(ctx, :trend_heading_html, "") <> ~s(<div class="chart-wrap"><canvas id="chart"></canvas></div>), else: ""}

      #{if ctx.page_kind != "master", do: ~s(<div id="machine-tabs" class="tabs"></div>), else: ""}

      #{if ctx.page_kind != "master", do: ~s(<div id="machine-specs" class="machine-specs"></div>), else: ""}

      #{if ctx.page_kind != "master" do
        ~s"""
        <div class="controls">
          <div class="group" id="control-flavor">
            <b>Flavor</b>
          </div>
          <div class="group" id="control-lang">
            <b>Language</b>
          </div>
          <div class="group" id="control-display">
            <b>Display</b>
            <label><input type="checkbox" id="show-whiskers" checked> Error bars</label>
          </div>
          <button id="reset-filters" type="button" class="reset-btn" title="Restore default tabs, language, and snapshot-major selections">Reset to defaults</button>
        </div>
        """
      else
        ""
      end}

      #{Map.get(ctx, :snapshot_html, "")}

      #{if ctx.page_kind != "suite", do: ~s(<div class="chart-wrap"><canvas id="chart"></canvas></div>), else: ""}

      #{if ctx.page_kind == "bench", do: ~s(<div id="spark-panel" class="spark-panel"></div>), else: ""}

      #{if ctx.page_kind == "master" do
        ~s"""
        <div id="master-drill-chart-wrap" class="master-drill-chart-wrap" style="display:none">
          <canvas id="master-drill-shared-chart"></canvas>
        </div>
        <div id="master-drill" class="master-drill"></div>
        <div id="master-drill-mix-modal" class="modal-overlay" style="display:none" role="dialog" aria-modal="true">
          <div class="modal-card">
            <h3>Add a different platform?</h3>
            <p>The pinned cards are currently all on <strong id="master-drill-mix-existing"></strong>. You're about to add <strong id="master-drill-mix-new"></strong>.</p>
            <p class="sub">The bars in the comparison chart are <em>speedup vs each platform's own earliest measurement</em> — a 5.2× on linux-x86_64 and a 4.8× on macos-arm64 each mean "this commit is N× faster than that platform's OTP-20.3 baseline". They're comparable as relative progress but <strong>not</strong> as absolute throughput — different hardware, different baselines. Pinning across platforms in the same chart is usually a misread.</p>
            <div class="modal-actions">
              <button id="master-drill-mix-cancel" type="button" class="reset-btn">Cancel</button>
              <button id="master-drill-mix-clear" type="button" class="reset-btn">Add + Clear others</button>
              <button id="master-drill-mix-add" type="button" class="reset-btn">Add anyway</button>
            </div>
          </div>
        </div>
        """
      else
        ""
      end}

      #{Map.get(ctx, :benchmarks_list_html, "")}

      #{Map.get(ctx, :extra_links_html, "")}

      <details>
        <summary>Run metadata</summary>
        <pre id="runs-meta"></pre>
      </details>

      <script>
      const PAGE_KIND = #{inspect(ctx.page_kind)};
      const BENCH_NAME = #{inspect(ctx.bench_name)};
      const BASELINE_LABEL = #{inspect(ctx.baseline_label)};
      const DATASET = #{ctx.dataset_json};
      const MAX_RELEASED_MAJOR = #{max_released_major()};
      const TARGET_ELIXIR_BY_MAJOR = #{Jason.encode!(target_elixir_by_major())};
      </script>
      <script>
      #{dashboard_js()}
      </script>
    </body>
    </html>
    """
  end

  defp dashboard_js, do: @dashboard_js

  # Build a {major => target_elixir_version} map by invoking
  # priv/elixir-for-otp.sh — the single source of truth for OTP →
  # Elixir pairings shared with bench.yml, the install scripts, and
  # measure-all-macos.sh. The script is the API; we don't parse it.
  # 20..30 covers everything we currently expose; extend the range
  # when a new major lands. Falls back to script's default branch
  # for any non-numeric major (master, maint).
  defp target_elixir_by_major do
    script = Path.join(:code.priv_dir(:awfy_runner), "elixir-for-otp.sh")

    Enum.reduce(20..30, %{}, fn major, acc ->
      case System.cmd(script, [to_string(major)], stderr_to_stdout: true) do
        {output, 0} ->
          version = String.trim(output)
          if version == "", do: acc, else: Map.put(acc, to_string(major), version)

        _ ->
          acc
      end
    end)
  end
end
