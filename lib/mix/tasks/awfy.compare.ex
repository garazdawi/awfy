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

    baseline_label = opts[:baseline] || latest_label(data.runs)

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

  defp latest_label(runs) do
    runs
    |> Enum.max_by(& &1.timestamp, fn -> nil end)
    |> case do
      nil -> nil
      run -> run.label
    end
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
        "Median runtime in milliseconds. Each line = one (lang × machine × arch × emu_flavor) combination across runs.",
      breadcrumb: """
      <a href="../index.html">&larr; Suite overview</a>
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
        "Geometric mean of `median / baseline_median` across all benchmarks. Lower is faster. Each line = one (lang × machine × arch × emu_flavor) combination.",
      breadcrumb: "",
      warnings_html: warnings_html(warnings),
      dataset_json: dataset_json,
      page_kind: "suite",
      bench_name: "",
      baseline_label: baseline_label || "",
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

  defp collect_warnings_suite(_rows, runs) do
    warnings = []

    machines =
      runs
      |> Enum.map(fn r -> {r.machine["hostname"], r.machine["cpu"]} end)
      |> Enum.reject(fn {h, _} -> is_nil(h) end)
      |> Enum.uniq()

    warnings =
      case machines do
        [_] -> warnings
        [] -> warnings
        many -> ["machines differ across runs: #{inspect(many)}" | warnings]
      end

    flavors =
      runs
      |> Enum.map(fn r -> r.runtime["emu_flavor"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    warnings =
      case flavors do
        [_] -> warnings
        [] -> warnings
        many -> ["emu_flavor differs across runs: #{inspect(many)}" | warnings]
      end

    Enum.reverse(warnings)
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
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 1100px; margin: 2rem auto; padding: 0 1rem; color: #222; }
        h1 { margin-bottom: 0.25rem; }
        h1 + .sub { color: #666; margin-top: 0; margin-bottom: 1rem; }
        .breadcrumb { margin-bottom: 1rem; }
        .breadcrumb a { color: #06c; text-decoration: none; }
        .warnings { background: #fff8e1; border-left: 4px solid #f6b73c; padding: 0.5rem 1rem; margin: 1rem 0; }
        .controls { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-bottom: 1rem; }
        .filter-group { border: 1px solid #ddd; border-radius: 4px; padding: 0.5rem 0.75rem; }
        .filter-group h4 { margin: 0 0 0.5rem 0; font-size: 0.85rem; text-transform: uppercase; color: #555; letter-spacing: 0.05em; }
        .filter-group label { display: block; font-size: 0.9rem; margin-bottom: 0.15rem; cursor: pointer; }
        .x-axis-toggle { font-size: 0.9rem; }
        canvas { width: 100% !important; height: 480px !important; }
        .bench-links { columns: 3; }
        .bench-links li { margin-bottom: 0.25rem; }
        details { margin-top: 1rem; }
        summary { cursor: pointer; color: #555; }
        pre { background: #f4f4f4; padding: 0.5rem; overflow-x: auto; font-size: 0.85rem; }
      </style>
    </head>
    <body>
      <div class="breadcrumb">#{ctx.breadcrumb}</div>
      <h1>#{ctx.heading}</h1>
      <p class="sub">#{ctx.subhead}</p>

      #{ctx.warnings_html}

      <div class="controls">
        <div class="x-axis-toggle">
          <label>X axis:
            <select id="x-axis">
              <option value="timestamp" selected>by timestamp</option>
              <option value="otp">by OTP version</option>
            </select>
          </label>
        </div>
        <div class="filter-group" id="filter-lang">
          <h4>Language</h4>
        </div>
        <div class="filter-group" id="filter-machine">
          <h4>Machine</h4>
        </div>
        <div class="filter-group" id="filter-arch">
          <h4>Arch</h4>
        </div>
        <div class="filter-group" id="filter-emu_flavor">
          <h4>Emu flavor</h4>
        </div>
      </div>

      <canvas id="chart"></canvas>

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
      return [row.lang, row.hostname, row.arch, row.emu_flavor].join(" / ");
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

    function buildFilterUI(field, values, state) {
      const container = document.getElementById("filter-" + field);
      const persisted = state[field];
      values.forEach(v => {
        const id = "f-" + field + "-" + v.replace(/[^a-z0-9]/gi, "_");
        const div = document.createElement("label");
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.id = id;
        cb.dataset.field = field;
        cb.dataset.value = v;
        cb.checked = persisted ? persisted.includes(v) : true;
        cb.addEventListener("change", onFilterChange);
        div.appendChild(cb);
        div.appendChild(document.createTextNode(" " + v));
        container.appendChild(div);
      });
    }

    function activeFilters() {
      const state = {};
      ["lang", "hostname", "arch", "emu_flavor"].forEach(field => {
        state[field] = [...document.querySelectorAll(
          'input[type=checkbox][data-field="' + field + '"]:checked'
        )].map(cb => cb.dataset.value);
      });
      // The container UI key is `machine` but the row field is `hostname`.
      state.machine = state.hostname;
      delete state.hostname;
      return state;
    }

    function onFilterChange() {
      const state = readUIState();
      saveFilterState(state);
      renderChart();
    }

    function readUIState() {
      const state = {};
      ["lang", "machine", "arch", "emu_flavor"].forEach(field => {
        const sel = field === "machine" ? "hostname" : field;
        state[field] = [...document.querySelectorAll(
          'input[type=checkbox][data-field="' + sel + '"]:checked'
        )].map(cb => cb.dataset.value);
      });
      return state;
    }

    function applyFilters(rows, state) {
      return rows.filter(r =>
        (state.lang || []).includes(r.lang) &&
        (state.machine || []).includes(r.hostname) &&
        (state.arch || []).includes(r.arch) &&
        (state.emu_flavor || []).includes(r.emu_flavor)
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
          label: key,
          data: sorted.map(r => ({
            x: xAxis === "otp" ? r.otp : r.timestamp,
            y: r.median_ms,
            stddev: r.stddev_ms,
            run_label: r.label,
            inner_iter: r.inner_iter
          }))
        };
      });
    }

    /* For the suite page: roll up rows into per-(run × series) geomean
       ratios against the baseline label. */
    function buildSuiteSeries(rows, xAxis) {
      const baseline = (DATASET.runs.find(r => r.label === BASELINE_LABEL) || {}).label;
      if (!baseline) return [];

      // Group baseline rows by (series-key, benchmark) -> median_ms
      const baseRows = rows.filter(r => r.label === baseline);
      const baseIdx = {};
      baseRows.forEach(r => {
        const k = seriesKey(r) + "|" + r.benchmark;
        baseIdx[k] = r.median_ms;
      });

      // Group all rows by (label, series-key)
      const groups = {};
      rows.forEach(r => {
        const sk = seriesKey(r);
        const gk = r.label + "|" + sk;
        if (!groups[gk]) groups[gk] = { label: r.label, sk, rows: [], runMeta: null };
        groups[gk].rows.push(r);
        groups[gk].runMeta = DATASET.runs.find(x => x.label === r.label);
      });

      // For each group: intersection of benchmarks with baseline; geomean ratio.
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

        if (!seriesByKey[g.sk]) seriesByKey[g.sk] = { label: g.sk, data: [] };
        const xVal = xAxis === "otp" ? g.runMeta.otp : g.runMeta.timestamp;
        seriesByKey[g.sk].data.push({ x: xVal, y: gm, run_label: g.label, n_benchmarks: ratios.length });
      });

      // Sort each series' points
      Object.values(seriesByKey).forEach(s => {
        s.data.sort((a, b) => (a.x < b.x ? -1 : a.x > b.x ? 1 : 0));
      });

      return Object.values(seriesByKey);
    }

    let chart = null;

    function renderChart() {
      const xAxis = document.getElementById("x-axis").value;
      const state = readUIState();
      const filtered = applyFilters(DATASET.rows, state);

      const series = PAGE_KIND === "suite"
        ? buildSuiteSeries(filtered, xAxis)
        : buildSeries(filtered, xAxis);

      const palette = [
        "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
        "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf"
      ];

      const datasets = series.map((s, i) => ({
        label: s.label,
        data: s.data,
        borderColor: palette[i % palette.length],
        backgroundColor: palette[i % palette.length],
        fill: false,
        spanGaps: false,
        tension: 0.05,
        pointRadius: 4,
        pointHoverRadius: 6
      }));

      const yLabel = PAGE_KIND === "suite"
        ? "geomean ratio vs " + BASELINE_LABEL + " (lower = faster)"
        : "median ms";

      if (chart) chart.destroy();
      chart = new Chart(document.getElementById("chart"), {
        type: "line",
        data: { datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          parsing: false,
          interaction: { intersect: false, mode: "nearest" },
          scales: {
            x: xAxis === "timestamp"
              ? { type: "time", time: { tooltipFormat: "yyyy-MM-dd HH:mm", displayFormats: { hour: "MM/dd HH:mm" } }, title: { display: true, text: "timestamp" } }
              : { type: "category", title: { display: true, text: "OTP version" } },
            y: { title: { display: true, text: yLabel }, beginAtZero: PAGE_KIND === "suite" ? false : true }
          },
          plugins: {
            tooltip: {
              callbacks: {
                label: (ctx) => {
                  const r = ctx.raw;
                  const parts = [ctx.dataset.label + ": " + (r.y).toFixed(3)];
                  if (r.run_label) parts.push("run=" + r.run_label);
                  if (r.stddev !== undefined && r.stddev !== null) parts.push("σ=" + r.stddev.toFixed(2));
                  if (r.inner_iter) parts.push("iter=" + r.inner_iter);
                  if (r.n_benchmarks) parts.push("n=" + r.n_benchmarks);
                  return parts.join("  ");
                }
              }
            }
          }
        }
      });
    }

    function renderRunsMeta() {
      const lines = DATASET.runs.map(r =>
        r.timestamp + "  " + r.label.padEnd(20) +
        "  otp=" + r.otp + "  elixir=" + r.elixir +
        "  " + (r.hostname || "?") + " (" + (r.cpu || "?") + ")  emu=" + (r.emu_flavor || "?")
      );
      document.getElementById("runs-meta").textContent = lines.join("\\n");
    }

    /* Init */
    (function () {
      const state = loadFilterState();
      ["lang", "hostname", "arch", "emu_flavor"].forEach(field => {
        const containerField = field === "hostname" ? "machine" : field;
        const values = uniqueValues(DATASET.rows, field);
        buildFilterUI(field, values, { ...state, hostname: state.machine });
      });

      document.getElementById("x-axis").addEventListener("change", renderChart);
      renderRunsMeta();
      renderChart();
    })();
    """
  end
end
