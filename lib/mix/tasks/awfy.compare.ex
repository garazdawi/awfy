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

    Mix.shell().info("Wrote #{out_dir}/index.html (#{length(bench_names)} benchmark pages, plus stability.html)")
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
        <li><a href="stability.html">Benchmark stability on master</a> — sorted by noise (highest CV first)</li>
      </ul>
      """
    })
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

    table_rows =
      rows
      |> Enum.map(fn r ->
        cv = r.stddev_ms / r.median_ms * 100
        Map.put(r, :cv_pct, cv)
      end)
      |> Enum.sort_by(& &1.cv_pct, :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, rank} ->
        scenario =
          case Map.get(r, :input) do
            nil -> r.benchmark
            "" -> r.benchmark
            input -> "#{r.benchmark}/#{input}"
          end

        # Tier the CV cell so visual scan tracks magnitudes:
        # <1 % calm, 1–5 % yellow, >5 % red. Tuned to AWFY's typical
        # spread on the publish host.
        cv_class =
          cond do
            r.cv_pct >= 5.0 -> "stability-bad"
            r.cv_pct >= 1.0 -> "stability-warn"
            true -> "stability-good"
          end

        ~s"""
        <tr>
          <td class="rank">#{rank}</td>
          <td>#{scenario}</td>
          <td>#{r.lang || "—"}</td>
          <td>#{machine_class(%{"arch" => r.arch})}</td>
          <td>#{r.emu_flavor}</td>
          <td class="num">#{format_ms(r.median_ms)}</td>
          <td class="num">#{format_ms(r.stddev_ms)}</td>
          <td class="num #{cv_class}">#{:io_lib.format(~c"~.2f", [r.cv_pct]) |> List.to_string()} %</td>
          <td class="num">#{r.samples_n || "—"}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

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
    table.stability td.num { text-align: right; font-variant-numeric: tabular-nums; font-family: var(--mono); }
    table.stability td.rank { color: var(--er-muted); width: 3em; text-align: right; }
    .stability-good { color: var(--er-good); }
    .stability-warn { color: #b58900; }
    .stability-bad { color: var(--er-bad); font-weight: 600; }
    </style>
    </head>
    <body>
    <header class="site-header">
      <span class="brand"><a href="../">AWFY · Erlang/OTP</a></span>
      <span class="breadcrumb"><a href="index.html">&larr; Suite</a> · Stability</span>
    </header>
    <h1>Benchmark stability on master</h1>
    <p class="sub">Coefficient of variation (σ / median × 100 %) for every scenario measured on the master branch, latest run per (platform × flavor × language × benchmark). Higher means the median moves around more between samples, so smaller speedup changes need more replication before they're trustworthy.</p>
    <p class="sub">Heuristic thresholds: <span class="stability-good">&lt; 1 %</span> calm, <span class="stability-warn">1 – 5 %</span> watch, <span class="stability-bad">&gt; 5 %</span> noisy.</p>

    <table class="stability">
      <thead>
        <tr>
          <th>#</th>
          <th>scenario</th>
          <th>lang</th>
          <th>platform</th>
          <th>flavor</th>
          <th>median (ms)</th>
          <th>σ (ms)</th>
          <th>CV</th>
          <th>samples</th>
        </tr>
      </thead>
      <tbody>
    #{table_rows}
      </tbody>
    </table>
    </body>
    </html>
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
          "machine_class" => machine_class(%{"arch" => r.arch}),
          "emu_flavor" => r.emu_flavor,
          "lang" => r.lang,
          "input" => Map.get(r, :input),
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

      <div id="machine-tabs" class="tabs"></div>

      <div id="machine-specs" class="machine-specs"></div>

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

      #{Map.get(ctx, :snapshot_html, "")}

      #{if ctx.page_kind != "suite", do: ~s(<div class="chart-wrap"><canvas id="chart"></canvas></div>), else: ""}

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
