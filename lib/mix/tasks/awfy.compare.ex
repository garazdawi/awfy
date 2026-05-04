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
        "Geometric mean of <code>median / baseline_median</code> across all benchmarks. Pick a machine class above; each line = one language for that platform, normalized to its earliest data-point.",
      breadcrumb: "",
      warnings_html: warnings_html(warnings),
      dataset_json: dataset_json,
      page_kind: "suite",
      bench_name: "",
      baseline_label: baseline_label || "",
      snapshot_html: """
      <h3>Latest snapshot — per-benchmark across versions</h3>
      <p class="sub">Median runtime (ms) at the most recent run for each (OTP × benchmark) on the selected platform. Whiskers show ± 2σ.</p>
      <canvas id="snapshot"></canvas>
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
        canvas { width: 100% !important; height: 420px !important; }
        canvas#snapshot { height: 520px !important; }
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
          canvas { height: 340px !important; }
          canvas#snapshot { height: 600px !important; }
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

      <div id="machine-tabs" class="tabs"></div>

      <div class="controls">
        <div class="group" id="control-flavor">
          <b>Flavor</b>
        </div>
        <div class="group" id="control-lang">
          <b>Language</b>
        </div>
        <div class="group">
          <b>X axis</b>
          <label>
            <select id="x-axis">
              <option value="timestamp" selected>timestamp</option>
              <option value="otp">OTP version</option>
            </select>
          </label>
        </div>
      </div>

      <div id="headline" class="headline"></div>

      <canvas id="chart"></canvas>

      #{Map.get(ctx, :snapshot_html, "")}

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

    function uniqueValues(rows, field) {
      const set = new Set();
      rows.forEach(r => { if (r[field]) set.add(r[field]); });
      return [...set].sort();
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

    function buildCheckboxGroup(controlId, name, values, persisted) {
      const container = document.getElementById(controlId);
      values.forEach(v => {
        const lab = document.createElement("label");
        const inp = document.createElement("input");
        inp.type = "checkbox";
        inp.name = name;
        inp.value = v;
        inp.checked = persisted ? persisted.includes(v) : true;
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

    /* Build series: group rows by (lang, machine, arch, emu_flavor). */
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
          if (a[xKey] < b[xKey]) return -1;
          if (a[xKey] > b[xKey]) return 1;
          return a.timestamp < b.timestamp ? -1 : 1;
        });
        return {
          // Display label is just the language; machine class + flavor
          // are already encoded in the active tab + radio so repeating
          // them on every legend entry is noise.
          label: items[0].lang,
          data: sorted.map(r => {
            // Chart.js with `parsing: false` + time scale requires
            // numeric x (epoch ms) — strings get silently skipped on
            // mobile Safari, leaving an empty chart.
            const x = xAxis === "otp" ? r.otp : Date.parse(r.timestamp);
            const sigma = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
            return {
              x,
              y: r.median_ms,
              // For lineWithErrorBars: yMin/yMax are the whisker bounds.
              yMin: r.median_ms - sigma,
              yMax: r.median_ms + sigma,
              stddev: r.stddev_ms,
              run_label: r.label,
              inner_iter: r.inner_iter
            };
          })
        };
      });
    }

    /* For the suite page: roll up rows into per-(run × series) geomean
       ratios.

       Two modes for picking the (series-key, benchmark) → baseline_ms
       reference:

       1. Per-series (default). Each series uses its own earliest row
          (by timestamp) for each benchmark as the baseline. This makes
          the chart robust to mixed hostnames/labels — every series
          curve starts at 1.0 and shows its own trend.

       2. Pinned (when BASELINE_LABEL is explicitly set AND that label
          actually exists in DATASET.runs). All series normalize
          against rows from that label. Useful for "regression vs
          before-jit2" comparisons. Series whose hostname/arch/etc.
          differs from the pinned label have no reference and
          contribute nothing — that's intentional, the user asked for
          a specific reference.
    */
    function buildSuiteSeries(rows, xAxis) {
      const pinned = BASELINE_LABEL &&
        (DATASET.runs.find(r => r.label === BASELINE_LABEL) || null);

      const baseIdx = {};
      if (pinned) {
        rows.filter(r => r.label === BASELINE_LABEL).forEach(r => {
          const k = seriesKey(r) + "|" + r.benchmark;
          baseIdx[k] = r.median_ms;
        });
      } else {
        // Per-series-earliest baseline.
        rows.forEach(r => {
          const k = seriesKey(r) + "|" + r.benchmark;
          if (!baseIdx[k] || r.timestamp < baseIdx[k].ts) {
            baseIdx[k] = { ms: r.median_ms, ts: r.timestamp };
          }
        });
        Object.keys(baseIdx).forEach(k => { baseIdx[k] = baseIdx[k].ms; });
      }

      // Group all rows by (label, series-key)
      const groups = {};
      rows.forEach(r => {
        const sk = seriesKey(r);
        const gk = r.label + "|" + sk;
        if (!groups[gk]) groups[gk] = { label: r.label, sk, rows: [], runMeta: null };
        groups[gk].rows.push(r);
        groups[gk].runMeta = DATASET.runs.find(x => x.label === r.label);
      });

      const seriesByKey = {};
      Object.values(groups).forEach(g => {
        const ratios = [];
        g.rows.forEach(r => {
          const bk = g.sk + "|" + r.benchmark;
          const baseMs = baseIdx[bk];
          if (baseMs && r.median_ms) {
            ratios.push(r.median_ms / baseMs);
          }
        });
        if (ratios.length === 0) return;
        const sumLog = ratios.reduce((a, b) => a + Math.log(b), 0);
        const gm = Math.exp(sumLog / ratios.length);

        if (!seriesByKey[g.sk]) {
          // sk = "lang / machine_class / flavor" — for display strip
          // everything but the lang since the rest is already pinned by
          // the active tab + flavor radio.
          const langOnly = g.sk.split(" / ")[0];
          seriesByKey[g.sk] = { label: langOnly, data: [] };
        }
        // Convert timestamp string → epoch ms; Chart.js' time scale with
        // `parsing: false` ignores string x values on mobile Safari.
        const xVal = xAxis === "otp" ? g.runMeta.otp : Date.parse(g.runMeta.timestamp);
        seriesByKey[g.sk].data.push({ x: xVal, y: gm, run_label: g.label, n_benchmarks: ratios.length });
      });

      Object.values(seriesByKey).forEach(s => {
        s.data.sort((a, b) => (a.x < b.x ? -1 : a.x > b.x ? 1 : 0));
      });

      return Object.values(seriesByKey);
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
      const xAxis = document.getElementById("x-axis").value;
      const state = readUIState();
      const filtered = applyFilters(DATASET.rows, state);

      const series = PAGE_KIND === "suite"
        ? buildSuiteSeries(filtered, xAxis)
        : buildSeries(filtered, xAxis);

      const datasets = series.map((s, i) => ({
        label: s.label,
        data: s.data,
        borderColor: colorFor(i),
        backgroundColor: colorFor(i),
        fill: false,
        spanGaps: false,
        tension: 0.05,
        pointRadius: 4,
        pointHoverRadius: 6,
        // Error-bar style for lineWithErrorBars (per-bench page).
        errorBarColor: colorFor(i),
        errorBarWhiskerColor: colorFor(i),
        errorBarLineWidth: 1.5,
        errorBarWhiskerSize: 6
      }));

      const yLabel = PAGE_KIND === "suite"
        ? "geomean ratio (lower = faster)"
        : "median ms (lower = faster)";

      const chartType = PAGE_KIND === "bench" ? "lineWithErrorBars" : "line";

      // Shared font config — defaults are 12px which gets cramped on
      // mobile and even desktop dense charts. 13/14 reads cleanly.
      const tickFont = { family: "Montserrat, sans-serif", size: 13 };
      const titleFont = { family: "Montserrat, sans-serif", size: 13, weight: "600" };

      if (chart) chart.destroy();
      chart = new Chart(document.getElementById("chart"), {
        type: chartType,
        data: { datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          parsing: false,
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
                  type: "category",
                  title: { display: true, text: "OTP version", font: titleFont },
                  ticks: { font: tickFont },
                  grid: { color: "#eee" }
                },
            y: {
              title: { display: true, text: yLabel, font: titleFont },
              ticks: { font: tickFont },
              beginAtZero: PAGE_KIND === "suite" ? false : true,
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
                  const unit = PAGE_KIND === "suite" ? "×" : " ms";
                  let line = ctx.dataset.label + ": " + v + unit;
                  if (r.stddev !== undefined && r.stddev !== null) line += "  σ=" + r.stddev.toFixed(2);
                  if (r.n_benchmarks) line += "  (" + r.n_benchmarks + " benches)";
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
      const filtered = applyFilters(DATASET.rows, state);
      if (filtered.length === 0) {
        el.innerHTML = '<span class="empty">No data for this combination yet.</span>';
        return;
      }

      const otps = [...new Set(filtered.map(r => r.otp).filter(Boolean))]
        .sort((a, b) => parseFloat(a) - parseFloat(b));
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
        return { lang, speedup, n: benches.length };
      }).filter(Boolean);

      if (lines.length === 0) {
        el.innerHTML = '<span class="empty">No matching benchmarks across the two OTP endpoints.</span>';
        return;
      }

      el.innerHTML = lines.map(({ lang, speedup, n }) => {
        const pct = (speedup - 1) * 100;
        const word = pct >= 0 ? "faster" : "slower";
        const cls = pct >= 0 ? "speedup" : "slowdown";
        return '<div><strong>' + lang + '</strong>: OTP ' + newest +
               ' is <span class="num ' + cls + '">' + speedup.toFixed(2) + '×</span> ' +
               '<span class="' + cls + '">' + word + '</span> than OTP ' + oldest +
               ' <span class="num">(' + (pct >= 0 ? "+" : "") + pct.toFixed(1) + '%)</span>' +
               ' &nbsp; <span style="color: var(--er-muted); font-size: 0.9em;">geomean of ' + n + ' benchmarks</span></div>';
      }).join("");
    }

    /* ---- Per-benchmark snapshot bar chart -----------------------------
       Grouped horizontal bars: one row per benchmark, one bar per OTP
       version, stacked by language. Shows the most recent (OTP, lang,
       benchmark) row for the active machine_class + flavor; whiskers are
       ± 2σ. Lets you see at a glance which benches actually got faster.
    */
    function renderSnapshot() {
      const el = document.getElementById("snapshot");
      if (!el) return;

      const state = readUIState();
      const filtered = applyFilters(DATASET.rows, state);

      // Most recent row per (otp, lang, benchmark).
      const latest = {};
      filtered.forEach(r => {
        const k = r.otp + "|" + r.lang + "|" + r.benchmark;
        if (!latest[k] || r.timestamp > latest[k].timestamp) latest[k] = r;
      });
      const rows = Object.values(latest);
      if (rows.length === 0) {
        if (snapshotChart) snapshotChart.destroy();
        snapshotChart = null;
        el.style.display = "none";
        return;
      }
      el.style.display = "";

      const otps = [...new Set(rows.map(r => r.otp))].sort((a, b) => parseFloat(a) - parseFloat(b));
      const langs = [...new Set(rows.map(r => r.lang))].sort();
      const benches = [...new Set(rows.map(r => r.benchmark))].sort();

      // One dataset per (otp, lang). Bars are grouped by benchmark name
      // on the y axis (horizontal layout reads better with 14 names).
      const datasets = [];
      otps.forEach((otp, oi) => {
        langs.forEach((lang, li) => {
          const data = benches.map(b => {
            const r = latest[otp + "|" + lang + "|" + b];
            if (!r) return null;
            const sigma = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
            return { x: r.median_ms, xMin: r.median_ms - sigma, xMax: r.median_ms + sigma, y: b, raw: r };
          });
          datasets.push({
            label: "OTP " + otp + " · " + lang,
            data,
            backgroundColor: colorFor(oi * langs.length + li),
            borderColor: colorFor(oi * langs.length + li),
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
          indexAxis: "y",
          parsing: { xAxisKey: "x", yAxisKey: "y", xMinKey: "xMin", xMaxKey: "xMax" },
          interaction: { intersect: false, mode: "nearest" },
          // Give benchmark names enough room on the left without
          // truncating; Chart.js' default is to auto-fit, but the names
          // (Mandelbrot, DeltaBlue, …) need ~110 px to render without "…".
          layout: { padding: { left: 4, right: 12 } },
          scales: {
            x: {
              title: { display: true, text: "median ms (lower = faster)", font: titleFont },
              ticks: { font: tickFont },
              beginAtZero: true,
              grid: { color: "#eee" }
            },
            y: {
              ticks: { font: tickFont, autoSkip: false },
              grid: { display: false }
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
                title: (items) => items[0] && items[0].raw ? items[0].raw.y : "",
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
      buildCheckboxGroup("control-lang", "lang", langs, state.lang);

      document.getElementById("x-axis").addEventListener("change", renderAll);
      renderRunsMeta();
      renderAll();
    })();
    """
  end
end
