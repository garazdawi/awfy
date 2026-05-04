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

    Mix.shell().info("Wrote #{out_dir}/index.html (#{length(bench_names)} benchmark pages)")
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
      <p class="sub">Speedup (×) over the earliest recorded run for each (lang × machine_class × benchmark) baseline, evaluated at each major's latest patch. Bars above 1× are faster than baseline. Whiskers show ± 2σ.</p>
      <div class="snapshot-majors" id="control-snapshot-majors"></div>
      <div class="chart-wrap snapshot"><canvas id="snapshot"></canvas></div>
      """,
      trend_heading_html: """
      <h3>Geomean speedup over versions</h3>
      <p class="sub">Geometric mean of <code>baseline_median / median</code>, higher = faster. JIT only. Per-platform lines anchor at each platform's own earliest recorded run for every (lang × benchmark) — each line starts at 1× wherever its data begins. The thicker <strong>all platforms</strong> line is pinned to the earliest OTP version present on every platform, so cross-platform numbers are apples-to-apples. Chart is intentionally not configurable; toggle individual platforms via the legend.</p>
      """,
      benchmarks_list_html: """
      <h3>Benchmarks</h3>
      <ul class="bench-links">#{bench_links}</ul>
      """
    })
  end

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
          "machine_class" => machine_class(r.machine),
          "emu_flavor" => r.runtime["emu_flavor"]
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
          "machine_class" => machine_class(%{"arch" => r.arch}),
          "emu_flavor" => r.emu_flavor,
          "lang" => r.lang,
          "benchmark" => r.benchmark,
          "median_ms" => r.median_ms,
          "mean_ms" => r.mean_ms,
          "stddev_ms" => r.stddev_ms,
          "samples_n" => r.samples_n,
          "inner_iter" => r.inner_iter,
          "source_sha256" => r.source_sha256,
          "verified" => r.verified
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
        /* Palette pulled from erlang.org: brand red #a2003e, body #202020,
           border #dee2e6, link blue #0d6efd, Montserrat as the headline
           sans. Layout stays content-first — generous whitespace, no
           heavy chrome. */
        :root {
          --er-red: #a2003e;
          --er-red-soft: #fbeef2;
          --er-text: #202020;
          --er-muted: #6c757d;
          --er-border: #dee2e6;
          --er-bg: #ffffff;
          --er-tint: #f8f9fa;
          --er-link: #0d6efd;
          --er-good: #1f6f33;
          --er-bad: #b03030;
          --sans: "Montserrat", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
          --mono: Consolas, Monaco, "Andale Mono", "Ubuntu Mono", monospace;
        }
        * { box-sizing: border-box; }
        body {
          font-family: var(--sans);
          max-width: 1140px;
          margin: 0 auto;
          padding: 1.5rem 1.25rem 3rem;
          color: var(--er-text);
          background: var(--er-bg);
          line-height: 1.55;
        }
        a { color: var(--er-link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .site-header {
          display: flex; align-items: baseline; gap: 0.75rem;
          padding-bottom: 1rem; margin-bottom: 1.5rem;
          border-bottom: 4px solid var(--er-red);
        }
        .site-header .brand { font-weight: 700; font-size: 1.05rem; color: var(--er-red); letter-spacing: 0.02em; text-transform: uppercase; }
        .site-header .brand a { color: inherit; }
        .site-header .breadcrumb { color: var(--er-muted); font-size: 0.9rem; }
        .site-header .breadcrumb a { color: var(--er-muted); }
        h1 { font-weight: 700; font-size: 1.75rem; margin: 0 0 0.25rem; letter-spacing: -0.01em; }
        h1 + .sub { color: var(--er-muted); margin: 0 0 1.5rem; font-size: 0.95rem; }
        h3 { font-weight: 600; font-size: 1.15rem; margin-top: 2.5rem; margin-bottom: 0.25rem; padding-bottom: 0.4rem; border-bottom: 1px solid var(--er-border); }
        h3 + .sub { color: var(--er-muted); margin-top: 0.4rem; font-size: 0.9rem; }
        .warnings { background: #fff8e1; border-left: 4px solid #f6b73c; padding: 0.6rem 1rem; margin: 1rem 0; border-radius: 4px; }
        .warnings ul { margin: 0.25rem 0 0 1.25rem; padding: 0; }
        .headline {
          font-size: 1rem; line-height: 1.55;
          padding: 0.85rem 1.1rem; margin: 0 0 1.5rem;
          background: var(--er-red-soft);
          border-left: 4px solid var(--er-red);
          border-radius: 4px;
        }
        .headline .num { font-weight: 700; font-variant-numeric: tabular-nums; }
        .headline .speedup { color: var(--er-good); }
        .headline .slowdown { color: var(--er-bad); }
        .headline .empty { color: var(--er-muted); font-style: italic; }
        .tabs { display: flex; flex-wrap: wrap; gap: 0; border-bottom: 2px solid var(--er-border); margin-bottom: 1rem; }
        .tab { background: none; border: none; padding: 0.55rem 1.1rem; cursor: pointer; font: inherit; font-size: 0.95rem; color: var(--er-muted); border-bottom: 3px solid transparent; margin-bottom: -2px; transition: color 0.1s, border-color 0.1s; }
        .tab:hover { color: var(--er-red); }
        .tab.active { color: var(--er-red); border-bottom-color: var(--er-red); font-weight: 600; }
        .controls {
          display: flex; flex-wrap: wrap; gap: 1.25rem;
          align-items: center; margin-bottom: 1rem; font-size: 0.9rem;
          padding: 0.6rem 0.85rem;
          background: var(--er-tint);
          border: 1px solid var(--er-border);
          border-radius: 4px;
        }
        .controls .group { display: flex; gap: 0.55rem; align-items: center; flex-wrap: wrap; }
        .controls .group b { color: var(--er-text); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; }
        .controls label { cursor: pointer; user-select: none; }
        .controls select { font: inherit; padding: 0.15rem 0.35rem; border: 1px solid var(--er-border); border-radius: 3px; background: white; }
        .reset-btn {
          margin-left: auto; font: inherit; font-size: 0.85rem;
          padding: 0.3rem 0.7rem; cursor: pointer;
          background: white; color: var(--er-muted);
          border: 1px solid var(--er-border); border-radius: 3px;
        }
        .reset-btn:hover { color: var(--er-red); border-color: var(--er-red); }
        /* Chart.js responsive sizing (with maintainAspectRatio:false)
           reads the canvas's parent for dimensions and writes inline
           width/height back onto the canvas. Wrap each canvas in a
           .chart-wrap that owns the size, and *don't* style the
           canvas itself — Chart.js needs the freedom to set its CSS
           and bitmap dimensions in lock-step. */
        .chart-wrap { position: relative; width: 100%; height: 360px; margin: 1rem 0; }
        .chart-wrap.snapshot { height: 600px; }
        h3.snapshot-heading { margin-top: 1rem; }
        .snapshot-majors {
          display: flex; flex-wrap: wrap; align-items: center;
          gap: 0.85rem; font-size: 0.9rem; margin: 0.6rem 0;
        }
        .snapshot-majors b { color: var(--er-text); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; }
        .snapshot-majors label { cursor: pointer; user-select: none; display: inline-flex; gap: 0.25rem; align-items: center; }
        .bench-links { columns: 3; padding-left: 1.25rem; }
        .bench-links li { margin-bottom: 0.3rem; break-inside: avoid; }
        details { margin-top: 1.5rem; }
        summary { cursor: pointer; color: var(--er-muted); font-size: 0.9rem; }
        summary:hover { color: var(--er-text); }
        pre { background: var(--er-tint); padding: 0.6rem 0.8rem; overflow-x: auto; font-size: 0.82rem; font-family: var(--mono); border: 1px solid var(--er-border); border-radius: 4px; }
        code { font-family: var(--mono); background: var(--er-tint); padding: 0.05em 0.3em; border-radius: 3px; font-size: 0.9em; }
        @media (max-width: 600px) {
          body { padding: 1rem 0.75rem 2rem; }
          h1 { font-size: 1.4rem; }
          .chart-wrap { height: 300px; }
          .chart-wrap.snapshot { height: 520px; }
          .bench-links { columns: 2; }
          .tab { padding: 0.45rem 0.75rem; font-size: 0.85rem; }
        }
      </style>
    </head>
    <body>
      <header class="site-header">
        <span class="brand"><a href="../">AWFY · Erlang/OTP</a></span>
        <span class="breadcrumb">#{ctx.breadcrumb}</span>
      </header>
      <h1>#{ctx.heading}</h1>
      <p class="sub">#{ctx.subhead}</p>

      #{ctx.warnings_html}

      #{if ctx.page_kind == "suite", do: Map.get(ctx, :trend_heading_html, "") <> ~s(<div class="chart-wrap"><canvas id="chart"></canvas></div>), else: ""}

      <div id="machine-tabs" class="tabs"></div>

      <div class="controls">
        <div class="group" id="control-flavor">
          <b>Flavor</b>
        </div>
        <div class="group" id="control-lang">
          <b>Language</b>
        </div>
        <button id="reset-filters" type="button" class="reset-btn" title="Restore default tabs, language, and snapshot-major selections">Reset to defaults</button>
      </div>

      <div id="headline" class="headline"></div>

      #{Map.get(ctx, :snapshot_html, "")}

      #{if ctx.page_kind != "suite", do: ~s(<div class="chart-wrap"><canvas id="chart"></canvas></div>), else: ""}

      #{Map.get(ctx, :benchmarks_list_html, "")}

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
      </script>
      <script>
      #{dashboard_js()}
      </script>
    </body>
    </html>
    """
  end

  defp dashboard_js do
    """
    /* AWFY dashboard — vanilla JS, no framework. */

    const STORAGE_KEY = "awfy.filters." + PAGE_KIND + "." + BENCH_NAME;

    function seriesKey(row) {
      // Group by stable machine class (linux-x86_64 / macos-arm64 / …)
      // rather than ephemeral hostnames, so multi-CI runs collapse
      // into a single trend line per (lang × class × flavor).
      return [row.lang, row.machine_class, row.emu_flavor].join(" / ");
    }

    // Order OTP version strings: "20.0" < "20.1" < ... < "21.0" <
    // ... < "28.5" < "master". Compares dotted-numeric components
    // pairwise; "master" sorts after everything so the in-progress
    // tip lands at the right edge of the chart.
    function compareOtpVersions(a, b) {
      if (a === b) return 0;
      if (a === "master") return 1;
      if (b === "master") return -1;
      const pa = String(a).split(".").map(s => parseInt(s, 10) || 0);
      const pb = String(b).split(".").map(s => parseInt(s, 10) || 0);
      for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const av = pa[i] || 0;
        const bv = pb[i] || 0;
        if (av !== bv) return av - bv;
      }
      return 0;
    }

    function uniqueValues(rows, field) {
      const set = new Set();
      rows.forEach(r => { if (r[field]) set.add(r[field]); });
      return [...set].sort();
    }

    // Bucket every OTP label down to its "major" for grouped controls.
    // - "26.5" / "27.0" / "28" → "26" / "27" / "28"
    // - "master" / "main" / "maint-N" pass through verbatim — these
    //   are floating refs the operator opts in/out of explicitly.
    function majorOf(otp) {
      if (otp === "master" || otp === "main") return otp;
      if (typeof otp === "string" && otp.indexOf("maint-") === 0) return otp;
      const m = parseInt(otp, 10);
      return Number.isFinite(m) ? String(m) : null;
    }

    // MAX_RELEASED_MAJOR is injected by awfy.compare from the first
    // line of erlang/otp's otp_versions.table at build time. Falls
    // back to a hardcoded value if the fetch fails (offline build,
    // network blip) — see max_released_major/0 in awfy.compare.

    // The dashboard's default snapshot scope is "supported releases".
    // OTP support window covers the current and previous two majors;
    // master is always included as the rolling tip. Anything older
    // gets opted in via the major checkboxes under the snapshot.
    //
    // RC versions of an upcoming major (e.g. OTP-29.0-rc3) get
    // backfilled for trend visibility but don't shift the support
    // window — that's what the MAX_RELEASED_MAJOR constant guards.
    function defaultMajorsSet(allMajors) {
      const supported = new Set();
      allMajors.forEach(m => {
        if (m === "master" || m === "main") {
          supported.add(m);
          return;
        }
        if (/^[0-9]+$/.test(m)) {
          const n = parseInt(m, 10);
          if (n >= MAX_RELEASED_MAJOR - 2 && n <= MAX_RELEASED_MAJOR) {
            supported.add(m);
          }
        }
      });
      return supported;
    }

    // All majors currently present in the dataset, sorted.
    function allMajorsInData() {
      const set = new Set();
      DATASET.rows.forEach(r => {
        const m = majorOf(r.otp);
        if (m) set.add(m);
      });
      return [...set].sort(compareOtpVersions);
    }

    // The active set of enabled snapshot majors — driven by the
    // checkbox row. Persists in filter state so a manual toggle
    // survives reloads.
    function enabledSnapshotMajorsSet() {
      const all = allMajorsInData();
      const state = loadFilterState();
      if (state.snapshot_majors && Array.isArray(state.snapshot_majors)) {
        return new Set(state.snapshot_majors.filter(m => all.includes(m)));
      }
      return defaultMajorsSet(all);
    }

    function loadFilterState() {
      try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}; }
      catch (e) { return {}; }
    }

    function saveFilterState(state) {
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); }
      catch (e) {}
    }

    /* ---- Filter state (tabs + radio + checkboxes) ----------------------
       Machine class becomes a tab strip — exclusive selection — because
       overlaying linux-x86_64, linux-arm64, macos-arm64, windows-x86_64
       on one chart drowns the trend. Flavor becomes a radio for the same
       reason (jit/emu run different code paths; comparing them on one
       axis is rarely what you want). Languages stay as multi-select
       checkboxes since seeing erlang and elixir together is the point.
    */

    function buildTabs(values, persisted, fallback) {
      const container = document.getElementById("machine-tabs");
      const initial =
        (persisted && values.includes(persisted)) ? persisted :
        (fallback && values.includes(fallback)) ? fallback :
        values[0];
      values.forEach(v => {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "tab" + (v === initial ? " active" : "");
        btn.dataset.value = v;
        btn.textContent = v;
        btn.addEventListener("click", () => {
          container.querySelectorAll(".tab").forEach(t => t.classList.remove("active"));
          btn.classList.add("active");
          onFilterChange();
        });
        container.appendChild(btn);
      });
    }

    function buildRadioGroup(controlId, name, values, persisted, fallback) {
      const container = document.getElementById(controlId);
      const initial =
        (persisted && values.includes(persisted)) ? persisted :
        (fallback && values.includes(fallback)) ? fallback :
        values[0];
      values.forEach(v => {
        const lab = document.createElement("label");
        const inp = document.createElement("input");
        inp.type = "radio";
        inp.name = name;
        inp.value = v;
        inp.checked = (v === initial);
        inp.addEventListener("change", onFilterChange);
        lab.appendChild(inp);
        lab.appendChild(document.createTextNode(" " + v));
        container.appendChild(lab);
      });
    }

    function buildCheckboxGroup(controlId, name, values, persisted, defaultPredicate) {
      const container = document.getElementById(controlId);
      values.forEach(v => {
        const lab = document.createElement("label");
        const inp = document.createElement("input");
        inp.type = "checkbox";
        inp.name = name;
        inp.value = v;
        inp.checked = persisted
          ? persisted.includes(v)
          : (defaultPredicate ? !!defaultPredicate(v) : true);
        inp.addEventListener("change", onFilterChange);
        lab.appendChild(inp);
        lab.appendChild(document.createTextNode(" " + v));
        container.appendChild(lab);
      });
    }

    function onFilterChange() {
      const state = readUIState();
      saveFilterState(state);
      renderAll();
    }

    // The major-checkbox row under the snapshot. Each box toggles
    // one OTP major (or "master") on the snapshot chart. Default
    // checked: the supported window per defaultMajorsSet/0 — older
    // majors are opt-in. Persists in localStorage like the other
    // filter controls.
    function buildSnapshotMajorCheckboxes() {
      const container = document.getElementById("control-snapshot-majors");
      if (!container) return;
      const all = allMajorsInData();
      const enabled = enabledSnapshotMajorsSet();
      container.innerHTML = "";
      const heading = document.createElement("b");
      heading.textContent = "Show majors:";
      container.appendChild(heading);
      all.forEach(m => {
        const lab = document.createElement("label");
        const inp = document.createElement("input");
        inp.type = "checkbox";
        inp.name = "snapshot_major";
        inp.value = m;
        inp.checked = enabled.has(m);
        inp.addEventListener("change", () => {
          const checked = [...container.querySelectorAll('input[name="snapshot_major"]:checked')]
            .map(el => el.value);
          const state = loadFilterState();
          state.snapshot_majors = checked;
          saveFilterState(state);
          renderHeadline();
          renderSnapshot();
        });
        lab.appendChild(inp);
        lab.appendChild(document.createTextNode(" " + m));
        container.appendChild(lab);
      });
    }

    function readUIState() {
      const activeTab = document.querySelector("#machine-tabs .tab.active");
      return {
        machine_class: activeTab ? activeTab.dataset.value : null,
        emu_flavor: (document.querySelector('input[name="flavor"]:checked') || {}).value,
        lang: [...document.querySelectorAll('input[name="lang"]:checked')].map(c => c.value)
      };
    }

    function applyFilters(rows, state) {
      return rows.filter(r =>
        (state.lang || []).includes(r.lang) &&
        r.machine_class === state.machine_class &&
        r.emu_flavor === state.emu_flavor
      );
    }

    /* Build series: group rows by (lang, machine, arch, emu_flavor).
       Per-bench page only — y values are baseline_ms / current_ms so
       higher = faster than the earliest run for that series, matching
       the suite chart's "× over baseline" framing. Whisker bounds
       map cleanly: ymin/ymax in ms invert to baseline/(ms+2σ) and
       baseline/(ms-2σ) respectively.
    */
    function buildSeries(rows, xAxis) {
      const groups = {};
      rows.forEach(row => {
        const key = seriesKey(row);
        if (!groups[key]) groups[key] = [];
        groups[key].push(row);
      });

      const xKey = xAxis === "otp" ? "otp" : "timestamp";

      return Object.entries(groups).map(([key, items]) => {
        const sorted = [...items].sort((a, b) => {
          if (xKey === "otp") {
            const c = compareOtpVersions(a.otp, b.otp);
            if (c !== 0) return c;
          } else if (a[xKey] !== b[xKey]) {
            return a[xKey] < b[xKey] ? -1 : 1;
          }
          return a.timestamp < b.timestamp ? -1 : 1;
        });
        // Baseline = earliest row in this series with a usable median.
        const base = sorted.find(r => typeof r.median_ms === "number" && r.median_ms > 0);
        const baseMs = base ? base.median_ms : null;
        return {
          // Display label is just the language; machine class + flavor
          // are already encoded in the active tab + radio so repeating
          // them on every legend entry is noise.
          label: items[0].lang,
          data: sorted.map(r => {
            const x = xAxis === "otp" ? r.otp : Date.parse(r.timestamp);
            const sigma = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
            const ratio = (baseMs && r.median_ms) ? baseMs / r.median_ms : null;
            const yMax = (baseMs && r.median_ms - sigma > 0) ? baseMs / (r.median_ms - sigma) : ratio;
            const yMin = (baseMs && r.median_ms + sigma > 0) ? baseMs / (r.median_ms + sigma) : ratio;
            return {
              x,
              y: ratio,
              yMin,
              yMax,
              median_ms: r.median_ms,
              stddev: r.stddev_ms,
              run_label: r.label,
              inner_iter: r.inner_iter,
              base_ms: baseMs
            };
          })
        };
      });
    }

    /* Suite geomean: combined-language, per-platform speedup over the
       earliest recorded run.

       Filter:
         - JIT only — emu is a separate, smaller story.

       Baselines (hybrid):
         - Per-platform lines: each (lang, machine_class, benchmark)
           anchors at its OWN earliest OTP version (compareOtpVersions
           ordering, timestamp tiebreak). Each platform's line starts
           at 1× — pragmatic, lets every platform tell its own story
           even when they joined the dashboard at different OTPs.
         - "All platforms" combined line: pinned to the earliest OTP
           version present on EVERY platform (the intersection of
           per-platform OTP sets). All ratios on the combined line
           are then comparable apples-to-apples; no platform is
           credited for progress that happened before it was
           measured. Loses early history but keeps the cross-platform
           number coherent.

       Output ratio:
         - baseline_ms / current_ms, so higher = faster than baseline.

       Series:
         - One per machine_class.
         - Plus an "all platforms" series, only plotted at OTPs ≥ pin.

       Filter state from the controls is intentionally ignored — this
       chart is always the headline view.
    */
    function buildSuiteGeomeanSeries() {
      const rows = DATASET.rows.filter(r => r.emu_flavor === "jit");

      const runOtp = {};
      DATASET.runs.forEach(r => { runOtp[r.label] = r.otp; });

      // Per-platform-per-lang baselines: earliest OTP version per
      // (lang, machine_class, benchmark), tiebreak by timestamp.
      const baseIdx = {};
      rows.forEach(r => {
        const otp = runOtp[r.label];
        if (!otp) return;
        const k = r.lang + "|" + r.machine_class + "|" + r.benchmark;
        const cur = baseIdx[k];
        if (!cur ||
            compareOtpVersions(otp, cur.otp) < 0 ||
            (compareOtpVersions(otp, cur.otp) === 0 && r.timestamp < cur.ts)) {
          baseIdx[k] = { ms: r.median_ms, otp, ts: r.timestamp };
        }
      });

      // Pin for the combined line: earliest OTP version present on
      // every platform (intersection of per-mc OTP sets).
      const otpsByMc = {};
      rows.forEach(r => {
        const otp = runOtp[r.label];
        if (!otp) return;
        if (!otpsByMc[r.machine_class]) otpsByMc[r.machine_class] = new Set();
        otpsByMc[r.machine_class].add(otp);
      });
      const mcs = Object.keys(otpsByMc);
      let commonOtps = mcs.length ? [...otpsByMc[mcs[0]]] : [];
      for (let i = 1; i < mcs.length; i++) {
        commonOtps = commonOtps.filter(o => otpsByMc[mcs[i]].has(o));
      }
      commonOtps.sort(compareOtpVersions);
      const pinnedOtp = commonOtps[0] || null;

      // Combined-line baseline: median at the pinned OTP per
      // (lang, machine_class, benchmark). If multiple runs share the
      // pinned OTP (re-runs), pick the earliest timestamp.
      const pinnedBaseIdx = {};
      if (pinnedOtp) {
        rows.forEach(r => {
          if (runOtp[r.label] !== pinnedOtp) return;
          if (typeof r.median_ms !== "number" || r.median_ms <= 0) return;
          const k = r.lang + "|" + r.machine_class + "|" + r.benchmark;
          if (!pinnedBaseIdx[k] || r.timestamp < pinnedBaseIdx[k].ts) {
            pinnedBaseIdx[k] = { ms: r.median_ms, ts: r.timestamp };
          }
        });
      }

      // Bucket ratios for the per-platform lines.
      const archByMcOtp = {};
      rows.forEach(r => {
        const otp = runOtp[r.label];
        if (!otp || !r.median_ms) return;
        const bk = r.lang + "|" + r.machine_class + "|" + r.benchmark;
        const base = baseIdx[bk];
        if (!base || !base.ms) return;
        const ratio = base.ms / r.median_ms;

        if (!archByMcOtp[r.machine_class]) archByMcOtp[r.machine_class] = {};
        if (!archByMcOtp[r.machine_class][otp]) archByMcOtp[r.machine_class][otp] = [];
        archByMcOtp[r.machine_class][otp].push(ratio);
      });

      // Combined line: only OTPs ≥ pin, ratios against pinnedBaseIdx.
      const allByOtp = {};
      if (pinnedOtp) {
        rows.forEach(r => {
          const otp = runOtp[r.label];
          if (!otp || !r.median_ms) return;
          if (compareOtpVersions(otp, pinnedOtp) < 0) return;
          const bk = r.lang + "|" + r.machine_class + "|" + r.benchmark;
          const base = pinnedBaseIdx[bk];
          if (!base || !base.ms) return;
          const ratio = base.ms / r.median_ms;
          if (!allByOtp[otp]) allByOtp[otp] = [];
          allByOtp[otp].push(ratio);
        });
      }

      const geomean = (ratios) => {
        if (!ratios || ratios.length === 0) return null;
        const sumLog = ratios.reduce((a, b) => a + Math.log(b), 0);
        return Math.exp(sumLog / ratios.length);
      };

      const archSeries = Object.entries(archByMcOtp)
        .sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)
        .map(([mc, byOtp]) => ({
          label: mc,
          data: Object.entries(byOtp)
            .map(([otp, ratios]) => ({ x: otp, y: geomean(ratios), n_benchmarks: ratios.length }))
            .sort((a, b) => compareOtpVersions(a.x, b.x))
        }));

      const allSeries = pinnedOtp ? {
        label: "all platforms (pinned to OTP " + pinnedOtp + ")",
        data: Object.entries(allByOtp)
          .map(([otp, ratios]) => ({ x: otp, y: geomean(ratios), n_benchmarks: ratios.length, pinnedOtp }))
          .sort((a, b) => compareOtpVersions(a.x, b.x)),
        // Visually distinct: bold black line so the combined trend
        // doesn't blend with the per-platform palette.
        borderColor: "#111",
        backgroundColor: "#111",
        borderWidth: 3
      } : null;

      return allSeries ? [allSeries, ...archSeries] : archSeries;
    }

    let chart = null;
    let snapshotChart = null;

    /* erlang.org-friendly palette: brand red on top, then the standard
       categorical wheel. Order matters — the first dataset (almost
       always erlang) gets the red. */
    const PALETTE = [
      "#a2003e", "#0d6efd", "#1f6f33", "#e07b00", "#7b3eb3",
      "#6c757d", "#a05a2c", "#0a8f8f", "#bcbd22"
    ];

    function colorFor(i) { return PALETTE[i % PALETTE.length]; }

    function renderChart() {
      // X axis is always OTP version. Suite uses the configurable-free
      // geomean builder; per-bench uses the standard series builder
      // (filtered against the controls).
      const xAxis = "otp";
      const state = readUIState();
      const series = PAGE_KIND === "suite"
        ? buildSuiteGeomeanSeries()
        : buildSeries(applyFilters(DATASET.rows, state), xAxis);

      const datasets = series.map((s, i) => {
        const baseColor = s.borderColor || colorFor(i);
        return {
          label: s.label,
          data: s.data,
          borderColor: s.borderColor || baseColor,
          backgroundColor: s.backgroundColor || baseColor,
          borderWidth: s.borderWidth || 2,
          fill: false,
          spanGaps: false,
          tension: 0.05,
          pointRadius: 4,
          pointHoverRadius: 6,
          // Error-bar style for lineWithErrorBars (per-bench page).
          errorBarColor: baseColor,
          errorBarWhiskerColor: baseColor,
          errorBarLineWidth: 1.5,
          errorBarWhiskerSize: 6
        };
      });

      const yLabel = PAGE_KIND === "suite"
        ? "geomean speedup (× over earliest, higher = faster)"
        : "speedup × (over earliest run, higher = faster)";

      const chartType = PAGE_KIND === "bench" ? "lineWithErrorBars" : "line";

      // Shared font config — defaults are 12px which gets cramped on
      // mobile and even desktop dense charts. 13/14 reads cleanly.
      const tickFont = { family: "Montserrat, sans-serif", size: 13 };
      const titleFont = { family: "Montserrat, sans-serif", size: 13, weight: "600" };

      // Pre-compute the sorted set of OTP versions present in the
      // visible series; passing them as data.labels pins the
      // category-axis order so 20.0 < 20.1 < ... < master no matter
      // what order rows happen to arrive in.
      const otpLabels = xAxis === "otp"
        ? [...new Set(series.flatMap(s => s.data.map(d => d.x)))].sort(compareOtpVersions)
        : null;

      if (chart) chart.destroy();
      chart = new Chart(document.getElementById("chart"), {
        type: chartType,
        data: otpLabels ? { labels: otpLabels, datasets } : { datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          // Explicit parsing keys (not `parsing: false`) so the
          // lineWithErrorBars controller picks up yMin/yMax on a
          // category x scale too. parsing: false works with numeric
          // x only — under the otp/category axis the per-bench
          // chart was rendering for one frame and then bailing.
          parsing: { xAxisKey: "x", yAxisKey: "y", yMinKey: "yMin", yMaxKey: "yMax" },
          interaction: { intersect: false, mode: "nearest" },
          scales: {
            x: xAxis === "timestamp"
              ? {
                  type: "time",
                  time: { tooltipFormat: "yyyy-MM-dd HH:mm", displayFormats: { hour: "MM/dd HH:mm", day: "MMM dd" } },
                  title: { display: true, text: "timestamp", font: titleFont },
                  ticks: { font: tickFont, maxRotation: 0, autoSkipPadding: 16 },
                  grid: { color: "#eee" }
                }
              : {
                  // Category, with labels pre-sorted by version (master
                  // last). Each tagged feature release (20.0, 20.1, …)
                  // becomes its own tick — no aggregation across
                  // patch-level versions.
                  type: "category",
                  title: { display: true, text: "OTP version", font: titleFont },
                  ticks: { font: tickFont, autoSkip: false, maxRotation: 0 },
                  grid: { color: "#eee" }
                },
            y: {
              title: { display: true, text: yLabel, font: titleFont },
              ticks: { font: tickFont },
              // Both modes are now ratios; let the axis breathe so
              // the spread above/below 1× is readable.
              beginAtZero: false,
              grid: { color: "#eee" }
            }
          },
          plugins: {
            legend: {
              position: "top",
              labels: { font: { family: "Montserrat, sans-serif", size: 13 }, boxWidth: 14, boxHeight: 14, padding: 12 }
            },
            tooltip: {
              backgroundColor: "rgba(32,32,32,0.92)",
              titleFont: { family: "Montserrat, sans-serif", size: 13, weight: "600" },
              bodyFont:  { family: "Montserrat, sans-serif", size: 13 },
              padding: 10,
              boxPadding: 4,
              callbacks: {
                title: (items) => {
                  if (!items.length) return "";
                  const r = items[0].raw;
                  if (xAxis === "otp") return "OTP " + r.x;
                  return new Date(r.x).toLocaleString();
                },
                label: (ctx) => {
                  const r = ctx.raw;
                  const v = (typeof r.y === "number") ? r.y.toFixed(3) : r.y;
                  let line = ctx.dataset.label + ": " + v + "×";
                  if (typeof r.median_ms === "number") line += "  (" + r.median_ms.toFixed(2) + " ms)";
                  if (r.stddev !== undefined && r.stddev !== null) line += "  σ=" + r.stddev.toFixed(2) + " ms";
                  if (r.n_benchmarks) line += "  (" + r.n_benchmarks + " ratios)";
                  return line;
                },
                afterBody: (items) => {
                  if (!items.length) return "";
                  const r = items[0].raw;
                  return r.run_label ? "run: " + r.run_label : "";
                }
              }
            }
          }
        }
      });
    }

    /* ---- Headline metric ----------------------------------------------
       "OTP X is N× faster than OTP Y on geomean of M benchmarks."
       Computed against the active machine_class + flavor. We pick the
       chronologically newest OTP version vs the chronologically oldest
       so it always reflects the most recent direction of travel.
    */
    function renderHeadline() {
      const el = document.getElementById("headline");
      if (!el) return;
      const state = readUIState();
      // The headline reads as a delta against the *earliest version
      // currently shown in the snapshot* — so toggling a major's
      // checkbox changes both panels in lockstep. On per-bench pages
      // the snapshot doesn't exist; fall through to "all available"
      // by treating every major as enabled.
      const enabledMajors = PAGE_KIND === "suite"
        ? enabledSnapshotMajorsSet()
        : new Set(allMajorsInData());
      const filtered = applyFilters(DATASET.rows, state)
        .filter(r => enabledMajors.has(majorOf(r.otp)));
      if (filtered.length === 0) {
        el.innerHTML = '<span class="empty">No data for this combination yet.</span>';
        return;
      }

      const otps = [...new Set(filtered.map(r => r.otp).filter(Boolean))]
        .sort(compareOtpVersions);
      if (otps.length < 2) {
        el.innerHTML = '<span class="empty">Need at least two OTP versions for a comparison.</span>';
        return;
      }
      const oldest = otps[0], newest = otps[otps.length - 1];

      const langs = [...new Set(filtered.map(r => r.lang))].sort();
      const lines = langs.map(lang => {
        // For each (lang, benchmark) pick the latest run on each end.
        const pickLatest = (otp) => {
          const m = {};
          filtered.filter(r => r.lang === lang && r.otp === otp).forEach(r => {
            if (!m[r.benchmark] || r.timestamp > m[r.benchmark].timestamp) m[r.benchmark] = r;
          });
          return m;
        };
        const oldRuns = pickLatest(oldest);
        const newRuns = pickLatest(newest);
        const benches = Object.keys(oldRuns).filter(b => newRuns[b] && oldRuns[b].median_ms && newRuns[b].median_ms);
        if (benches.length === 0) return null;
        const sumLog = benches.reduce((s, b) => s + Math.log(oldRuns[b].median_ms / newRuns[b].median_ms), 0);
        const speedup = Math.exp(sumLog / benches.length);
        return { lang, speedup, benches };
      }).filter(Boolean);

      if (lines.length === 0) {
        el.innerHTML = '<span class="empty">No matching benchmarks across the two OTP endpoints.</span>';
        return;
      }

      // Per-bench pages roll up exactly one benchmark, so name it
      // directly ("geomean of Bounce") — "1 benchmarks" is awkward.
      // Suite pages stay as a count.
      el.innerHTML = lines.map(({ lang, speedup, benches }) => {
        const pct = (speedup - 1) * 100;
        const word = pct >= 0 ? "faster" : "slower";
        const cls = pct >= 0 ? "speedup" : "slowdown";
        const scope = PAGE_KIND === "bench"
          ? BENCH_NAME
          : (benches.length === 1 ? benches[0] : benches.length + " benchmarks");
        return '<div><strong>' + lang + '</strong>: OTP ' + newest +
               ' is <span class="num ' + cls + '">' + speedup.toFixed(2) + '×</span> ' +
               '<span class="' + cls + '">' + word + '</span> than OTP ' + oldest +
               ' <span class="num">(' + (pct >= 0 ? "+" : "") + pct.toFixed(1) + '%)</span>' +
               ' &nbsp; <span style="color: var(--er-muted); font-size: 0.9em;">geomean of ' + scope + '</span></div>';
      }).join("");
    }

    /* ---- Per-benchmark snapshot bar chart -----------------------------
       Grouped vertical bars: one column per benchmark on the x axis,
       one bar per (OTP major, language) — only the latest patch of each
       major contributes. Y-axis is speedup (× over the earliest run for
       that lang × machine_class × flavor × benchmark) so higher = faster
       than baseline; bars at 1× match the earliest run. Whiskers map
       through the same inversion (yMin = base/(med+2σ), yMax = base/
       (med-2σ)). Lang filter defaults to Erlang only; toggle Elixir on
       to layer it in.
    */
    function renderSnapshot() {
      const el = document.getElementById("snapshot");
      if (!el) return;

      const state = readUIState();
      const enabledMajors = enabledSnapshotMajorsSet();
      const filtered = applyFilters(DATASET.rows, state)
        .filter(r => enabledMajors.has(majorOf(r.otp)));

      // Baseline index built from the unfiltered row set so toggling
      // the major checkboxes can never accidentally shift the baseline
      // — it's always the dataset's earliest recorded run for each
      // (lang, machine_class, flavor, benchmark). Anchored to OTP
      // version order, then timestamp as tiebreak.
      const baseIdx = {};
      DATASET.rows.forEach(r => {
        if (r.machine_class !== state.machine_class) return;
        if (r.emu_flavor !== state.emu_flavor) return;
        if (typeof r.median_ms !== "number" || r.median_ms <= 0) return;
        const k = r.lang + "|" + r.benchmark;
        const cur = baseIdx[k];
        const cmp = cur ? compareOtpVersions(r.otp, cur.otp) : -1;
        if (!cur || cmp < 0 || (cmp === 0 && r.timestamp < cur.ts)) {
          baseIdx[k] = { ms: r.median_ms, otp: r.otp, ts: r.timestamp };
        }
      });

      // Per-major collapse: only the latest patch per OTP major shows
      // in the snapshot — the trend chart still surfaces every patch.
      const latest = {};
      filtered.forEach(r => {
        const m = majorOf(r.otp);
        if (!m) return;
        const k = m + "|" + r.lang + "|" + r.benchmark;
        const cur = latest[k];
        if (!cur ||
            r.timestamp > cur.timestamp ||
            (r.timestamp === cur.timestamp && compareOtpVersions(r.otp, cur.otp) > 0)) {
          latest[k] = r;
        }
      });
      const rows = Object.values(latest);
      if (rows.length === 0) {
        if (snapshotChart) snapshotChart.destroy();
        snapshotChart = null;
        el.style.display = "none";
        return;
      }
      el.style.display = "";

      const majors = [...new Set(rows.map(r => majorOf(r.otp)))].sort(compareOtpVersions);
      const langs = [...new Set(rows.map(r => r.lang))].sort();
      const benches = [...new Set(rows.map(r => r.benchmark))].sort();
      const versionForMajor = {};
      rows.forEach(r => { versionForMajor[majorOf(r.otp)] = r.otp; });

      // One dataset per (major, lang). Bars are speedup ratios; whiskers
      // invert through the same baseline so they read as "× over base".
      const datasets = [];
      majors.forEach((m, mi) => {
        langs.forEach((lang, li) => {
          const data = benches.map(b => {
            const r = latest[m + "|" + lang + "|" + b];
            // Bar chart with parsing.yMinKey reads `.yMin` on every
            // datapoint, so bare null crashes Chart.js with
            // "Cannot read properties of null (reading 'yMin')".
            // Hand back an object with null fields instead — the bar
            // is skipped without breaking the parser.
            if (!r) return { x: b, y: null, yMin: null, yMax: null, raw: null };
            const base = baseIdx[lang + "|" + b];
            if (!base || !base.ms || !r.median_ms) {
              return { x: b, y: null, yMin: null, yMax: null, raw: r };
            }
            const ratio = base.ms / r.median_ms;
            const sigma = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
            const yMax = (r.median_ms - sigma > 0) ? base.ms / (r.median_ms - sigma) : ratio;
            const yMin = (r.median_ms + sigma > 0) ? base.ms / (r.median_ms + sigma) : ratio;
            return { x: b, y: ratio, yMin, yMax, raw: r, baseMs: base.ms };
          });
          const v = versionForMajor[m];
          const labelOtp = (v === "master" || v === "main") ? v : "OTP " + v;
          datasets.push({
            label: labelOtp + " · " + lang,
            data,
            backgroundColor: colorFor(mi * langs.length + li),
            borderColor: colorFor(mi * langs.length + li),
            errorBarColor: "rgba(0,0,0,0.45)",
            errorBarWhiskerColor: "rgba(0,0,0,0.45)",
            errorBarLineWidth: 1,
            errorBarWhiskerSize: 4
          });
        });
      });

      const tickFont = { family: "Montserrat, sans-serif", size: 13 };
      const titleFont = { family: "Montserrat, sans-serif", size: 13, weight: "600" };

      if (snapshotChart) snapshotChart.destroy();
      snapshotChart = new Chart(el, {
        type: "barWithErrorBars",
        data: { labels: benches, datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          parsing: { xAxisKey: "x", yAxisKey: "y", yMinKey: "yMin", yMaxKey: "yMax" },
          interaction: { intersect: false, mode: "nearest" },
          scales: {
            x: {
              type: "category",
              ticks: { font: tickFont, autoSkip: false, maxRotation: 0 },
              grid: { display: false }
            },
            y: {
              title: { display: true, text: "median ms (lower = faster)", font: titleFont },
              ticks: { font: tickFont },
              beginAtZero: true,
              grid: { color: "#eee" }
            }
          },
          plugins: {
            legend: {
              position: "top",
              labels: {
                font: { family: "Montserrat, sans-serif", size: 13 },
                boxWidth: 14, boxHeight: 14, padding: 12
              }
            },
            tooltip: {
              backgroundColor: "rgba(32,32,32,0.92)",
              titleFont: { family: "Montserrat, sans-serif", size: 13, weight: "600" },
              bodyFont:  { family: "Montserrat, sans-serif", size: 13 },
              padding: 10,
              boxPadding: 4,
              callbacks: {
                title: (items) => items[0] && items[0].raw ? items[0].raw.x : "",
                label: (ctx) => {
                  const r = ctx.raw && ctx.raw.raw;
                  if (!r) return ctx.dataset.label;
                  let line = ctx.dataset.label + ": " + r.median_ms.toFixed(2) + " ms";
                  if (r.stddev_ms !== undefined && r.stddev_ms !== null) line += "  σ=" + r.stddev_ms.toFixed(2);
                  return line;
                }
              }
            }
          }
        }
      });
    }

    function renderAll() {
      renderHeadline();
      renderChart();
      if (PAGE_KIND === "suite") renderSnapshot();
    }

    function renderRunsMeta() {
      const lines = DATASET.runs.map(r =>
        r.timestamp + "  " + r.label.padEnd(40) +
        "  otp=" + r.otp + "  elixir=" + r.elixir +
        "  " + (r.machine_class || r.hostname || "?") + " (" + (r.cpu || "?") + ")  emu=" + (r.emu_flavor || "?")
      );
      document.getElementById("runs-meta").textContent = lines.join("\\n");
    }

    /* Init */
    (function () {
      const state = loadFilterState();
      const machineClasses = uniqueValues(DATASET.rows, "machine_class");
      const flavors = uniqueValues(DATASET.rows, "emu_flavor");
      const langs = uniqueValues(DATASET.rows, "lang");

      // Defaults: Linux x86_64 + JIT — the cheapest, most-representative
      // combo. The tab + radio fall back here on a fresh visit; persisted
      // selections override.
      buildTabs(machineClasses, state.machine_class, "linux-x86_64");
      buildRadioGroup("control-flavor", "flavor", flavors, state.emu_flavor, "jit");
      // Default: Erlang only. Elixir is opt-in via the checkbox so the
      // snapshot's bar count starts manageable; toggle it on to layer
      // the second language alongside.
      buildCheckboxGroup("control-lang", "lang", langs, state.lang,
        (v) => v === "erlang");
      // The major-checkboxes container is only on the suite page;
      // skip on per-bench pages where the snapshot doesn't render.
      if (PAGE_KIND === "suite") {
        buildSnapshotMajorCheckboxes();
      }

      // Reset wipes this page's filter state and reloads. Per-page
      // STORAGE_KEY scoping means the index reset doesn't disturb
      // any per-bench page's selections, and vice versa.
      document.getElementById("reset-filters").addEventListener("click", () => {
        try { localStorage.removeItem(STORAGE_KEY); } catch (_) {}
        location.reload();
      });

      renderRunsMeta();
      renderAll();
    })();
    """
  end
end
