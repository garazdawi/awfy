<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# Versioned Bench Plan — `mix awfy.measure` + `mix awfy.compare`

A versioned-benchmark harness for comparing AWFY numbers across
Erlang/OTP and Elixir versions over time. Built for diff-the-JIT
workflows: run a measure, switch a runtime, run again, compare.

**Built on Benchee.** Benchee already does almost everything we
need — warmup, sampling, statistics (median, mean, stddev,
percentiles, ips), saving runs to disk, loading and comparing
multiple saved runs. The existing `Awfy.BencheeRunner` runs one
Benchee invocation per benchmark with Erlang+Elixir scenarios.
This plan adds a thin version-tagging layer on top, plus a
plot/compare command that loads multiple saves into a single
report.

## What Benchee gives us for free

- **Sampling loop**: configurable `time:`, `warmup:`, with
  per-iteration timing and ips computation.
- **Statistics**: `Benchee.Statistics` computes mean, median,
  stddev, ips, mode, percentiles, IQR, plus relative comparisons.
- **Save/load**: `save: [path: PATH, tag: TAG]` writes the full
  `Suite` struct to a `.benchee` binary file via
  `:erlang.term_to_binary/1`. `load: [PATH]` reads any number of
  saves back; tags appear next to scenario names in the report.
- **Formatters**: console (built-in), HTML (via `benchee_html`),
  JSON (via `benchee_json`), Markdown, CSV — all swappable.
- **Multi-run merging**: pass `load: [...]` and Benchee folds
  every loaded scenario into the new run as if it had been part
  of it, with tag suffixes for disambiguation.

So the only things we have to build are: a CLI surface that wires
Benchee's save/tag options to the active OTP+Elixir versions, a
shell wrapper that loops `asdf shell` and re-invokes the measure
task, and a compare command that loads saves and emits an HTML
report.

## Goals

1. **Run** the AWFY suite under the currently active OTP+Elixir,
   reusing `Awfy.BencheeRunner`, save each benchmark's run to a
   version-tagged `.benchee` file.
2. **Save** results under `results/`, named by OTP+Elixir+label,
   so multiple runs accumulate without colliding.
3. **Compare** any subset of saved runs as one chart per benchmark,
   showing each version's distribution side by side.

## Non-goals

- Running under non-asdf-managed BEAMs (works if asdf is bypassed
  — just point the wrapper at any `erl`/`mix` on `$PATH` — but
  not specially supported).
- Real-time monitoring or CI integration. The Benchee save format
  is CI-friendly; wiring it in is a follow-up.
- Microbenchmarking — `mix awfy.benchee` already does that for
  live tuning. This plan is the durable, multi-version sibling.

## UX

```text
# 1. Measure under the currently active OTP+Elixir.
$ mix awfy.measure                                  # auto-label from versions+timestamp
$ mix awfy.measure --label before-jit2              # custom label
$ mix awfy.measure --benchmarks Bounce,Json         # subset
$ mix awfy.measure --lang erlang                    # one language
$ mix awfy.measure --time 5 --warmup 1              # forwarded to Benchee

# 2. Run across multiple OTP versions (shell wrapper, see Phase 2).
$ ./bin/measure-versions 28.4.1 28.5.0 master
   # for each: asdf shell erlang $V && mix awfy.measure --label $V

# 3. Compare/plot.
$ mix awfy.compare                                  # all saves, HTML report
$ mix awfy.compare --benchmarks Bounce,Sieve        # subset
$ mix awfy.compare --labels v1,v2                   # specific saves
$ mix awfy.compare --console                        # text-only output
$ mix awfy.compare --out report.html                # default: results/index.html
```

## Layout under `results/`

`results/` directory at the awfy project root, gitignored. One
subdir per measurement run, holding one `.benchee` file per
benchmark (because `BencheeRunner` runs Benchee once per
benchmark — see "Why per-benchmark saves" below).

```
results/
├── 2026-05-01T12-34_otp28.4.1_elixir1.19.5_before-jit2/
│   ├── meta.json                # versions, machine info, timestamp
│   ├── Bounce.benchee
│   ├── List.benchee
│   ├── ...
│   └── Havlak.benchee
├── 2026-05-02T08-12_otp28.5.0_elixir1.19.5_after-jit2/
│   ├── meta.json
│   ├── Bounce.benchee
│   └── ...
└── index.html                   # produced by `mix awfy.compare`
```

`meta.json` is the only thing not handled by Benchee — it stores
context not captured in the `.benchee` files:

```json
{
  "label": "before-jit2",
  "otp": "28.4.1",
  "elixir": "1.19.5",
  "machine": {
    "hostname": "lukas-m5",
    "os": "Darwin 25.4.0",
    "cpu": "Apple M5",
    "cores": 12
  },
  "timestamp": "2026-05-01T12:34:56Z",
  "git_commit": "abc123",
  "git_dirty": false,
  "benchmarks": ["Bounce", "List", ...],
  "lang": "both"
}
```

The `.benchee` files contain Benchee's full `Suite` struct: every
sample, every statistic, formatter config. We never reach inside —
we just hand the path back to `Benchee.run(jobs_or_empty,
load: paths)` to merge them at compare time.

### Why per-benchmark saves (one `.benchee` per benchmark)

`BencheeRunner` already runs `Benchee.run/2` once per benchmark
(line 84), so the natural Benchee output is one save file per
benchmark. Two benefits over a single combined save:

1. **Different `inner_iter` per benchmark.** Bounce uses 1500,
   NBody uses 250000 — they can't share a Benchee run.
2. **Selective re-measurement.** When tweaking just one
   benchmark, re-running rewrites only that file.

The `mix awfy.compare` command stitches them back together.

## Components

### `mix awfy.measure`

Located at `lib/mix/tasks/awfy.measure.ex`. Pseudocode:

```elixir
defmodule Mix.Tasks.Awfy.Measure do
  use Mix.Task
  @impl true
  def run(args) do
    Mix.Task.run("compile")
    opts = parse(args)

    label = opts.label || auto_label()
    dir = Path.join("results", "#{timestamp()}_otp#{otp()}_elixir#{elixir()}_#{label}")
    File.mkdir_p!(dir)

    write_meta(dir, label, opts)

    Awfy.BencheeRunner.run_all(
      lang: opts.lang,
      benchee: [
        time: opts.time,
        warmup: opts.warmup,
        memory_time: 0,
        save: [path: Path.join(dir, "{benchmark_name}.benchee"), tag: label]
      ],
      benchmarks: opts.benchmarks
    )
  end
end
```

Two changes to `BencheeRunner`:

1. Accept a `:benchmarks` option to filter by name (currently it's
   all-or-one). Trivial extension.
2. Substitute `{benchmark_name}` in the `save: path:` template per
   run — `BencheeRunner.run_one/3` knows the name, so it can build
   `Path.join(dir, "#{name}.benchee")` before passing to Benchee.
   (Benchee's own `save: path:` is a fixed string, no templating.)

The verification check already happens inside the benchee scenario
function (`run_scenario` calls `Awfy.verify` and raises on
incorrect result). Benchee's exception-during-job behavior aborts
the run, which is what we want — we never save a save with a
broken benchmark.

### `bin/measure-versions` (shell wrapper)

```sh
#!/bin/sh
set -e
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT_ROOT"

for v in "$@"; do
  echo "=== OTP $v ==="
  asdf shell erlang "$v"
  # Per-version build dir to avoid .beam mismatches across OTP majors.
  export MIX_BUILD_PATH="_build/$v"
  mix deps.get >/dev/null
  mix compile >/dev/null
  mix awfy.measure --label "$v"
done
```

A Mix task wrapper for this is unnecessary — the script is short
and switching OTP versions from inside a running BEAM is
impossible (the runtime is already loaded). The script does need
to set `MIX_BUILD_PATH` per-version so `_build/dev/lib/awfy/ebin`
doesn't get clobbered by `.beam` files from a different OTP major.

### `mix awfy.compare`

Located at `lib/mix/tasks/awfy.compare.ex`. Pseudocode:

```elixir
defmodule Mix.Tasks.Awfy.Compare do
  use Mix.Task
  @impl true
  def run(args) do
    opts = parse(args)
    runs = discover_runs(opts.labels)            # list of dirs under results/
    benches = discover_benchmarks(runs, opts.benchmarks)

    Enum.each(benches, fn name ->
      paths = Enum.flat_map(runs, fn run ->
        path = Path.join(run.dir, "#{name}.benchee")
        if File.exists?(path), do: [path], else: []
      end)

      # Re-run Benchee with no jobs, only loads, to merge into a fresh suite
      # and run formatters.
      Benchee.run(%{},
        load: paths,
        formatters: formatters(opts, name)
      )
    end)

    if opts.html, do: render_index(runs, benches, "results/index.html")
  end

  defp formatters(opts, name) do
    base = [Benchee.Formatters.Console]
    if opts.html do
      [Benchee.Formatters.HTML, file: "results/per-bench/#{name}.html"] ++ base
    else
      base
    end
  end
end
```

Note: `Benchee.run(%{}, load: ...)` may not work if benchee
requires at least one new job. Check at implementation time; if
it complains, pass an empty no-op job or use the lower-level
`Benchee.Save.load/1` + `Benchee.Statistics.statistics/1` +
formatter call directly (those are documented public modules).

`results/index.html` is a small handwritten landing page that
links to the per-benchmark `benchee_html` outputs and shows a
summary matrix (rows = benchmarks, columns = labels, cells =
median ms, deltas vs baseline highlighted). 50 lines of EEx, no
chart libraries needed in the index page itself — Benchee's HTML
formatter renders the per-benchmark distributions.

## Dependencies to add

```elixir
# mix.exs
{:benchee_html, "~> 1.0", only: :dev},
{:benchee_json, "~> 1.0", only: :dev}     # optional, for CI ingestion
```

`benchee_html` produces a self-contained HTML file per scenario
group with interactive plotly.js charts: one bar chart of ips,
percentile distribution per scenario. With multiple loaded
scenarios (one per version-tag), the chart shows them side by
side — exactly the cross-version view we want.

`benchee_json` is a stretch goal for CI: emit a machine-readable
summary alongside the binary save.

## File layout

```
awfy/
├── lib/mix/tasks/
│   ├── awfy.measure.ex            # NEW
│   ├── awfy.compare.ex            # NEW
│   └── awfy.benchee.ex            # existing
├── lib/awfy/
│   └── benchee_runner.ex          # extend: :benchmarks filter, save: path templating
├── bin/
│   └── measure-versions           # NEW: shell wrapper, +x
├── results/                       # NEW: gitignored
│   ├── .gitkeep
│   ├── <timestamp>_otp<v>_elixir<v>_<label>/
│   │   ├── meta.json
│   │   └── *.benchee
│   ├── per-bench/                 # benchee_html output, written by awfy.compare
│   │   └── *.html
│   └── index.html                 # landing page, written by awfy.compare
├── BENCH_VERSIONS_PLAN.md         # this file
└── README.md                      # add a "Versioned benchmarks" section
```

## Implementation phases

### Phase 1 — `mix awfy.measure`

1. Extend `Awfy.BencheeRunner`:
   - `:benchmarks` option (list of names) — filter the
     enumeration before running.
   - Change `:benchee` opt's `:save` path to be templated; in
     `run_one/3`, substitute the benchmark name and ensure the
     dir exists.
2. Implement `Mix.Tasks.Awfy.Measure` (~80 lines):
   - CLI parsing with `OptionParser`.
   - Auto-label = `<git short SHA>` if clean, else
     `<sha>-dirty`; user override via `--label`.
   - `meta.json` write before invoking BencheeRunner.
   - Capture machine info: `:erlang.system_info(:system_architecture)`,
     `:inet.gethostname/0`, `:os.cpu_topology/0`.
   - Pass `save:` config through to BencheeRunner.
3. Tests: `Bounce`-only run with `--time 0 --warmup 0` (Benchee
   accepts these as a fast smoke run), assert that
   `results/.../Bounce.benchee` and `meta.json` exist with the
   expected shapes.
4. Update README with the new task.

### Phase 2 — Version-switching wrapper

1. `bin/measure-versions` — 10 lines of POSIX sh.
2. README documents the workflow.
3. Decide: do we want a Mix task that just `System.cmd("./bin/measure-versions", args)`?
   Probably not — it adds noise without value, and shell scripts
   are easier to grep-debug than Mix tasks.

### Phase 3 — `mix awfy.compare`

1. Add `benchee_html` (and optionally `benchee_json`) to
   `mix.exs` deps.
2. Implement `Mix.Tasks.Awfy.Compare`:
   - Discover `results/*/` directories, parse each `meta.json`.
   - `--labels`, `--benchmarks` filters.
   - For each benchmark: collect every save's path, hand to
     `Benchee.run(%{}, load: paths, formatters: ...)`. Emit a
     per-benchmark HTML via `Benchee.Formatters.HTML`.
   - Render a top-level `results/index.html` summary matrix with
     a small EEx template (no chart lib in the index — just
     numbers and links).
3. Verify `Benchee.run(%{}, load: ...)` works as expected; if
   not, fall back to `Benchee.Save.load/1` and call statistics +
   formatters manually.
4. Tests: synthetic `results/` fixture with two saved runs,
   assert the produced HTML mentions both labels and one canvas
   per benchmark.

### Phase 4 (stretch) — committed numbers

For the README's headline numbers, we copy chosen runs into
`results/.committed/` (or change `.gitignore` to track that subdir).
`mix awfy.compare --committed-only` then renders the canonical
chart that matches the README — readers can reproduce by checking
out the repo and running the task.

## Open questions

1. **Sample counts.** ✅ Decided: per-benchmark `:time` defaults in
   `BencheeRunner` (calibrated from observed medians; fast
   benchmarks get 8–10s for ~50–100 samples, slow ones get 4–5s).
   `--time` and `--warmup` CLI flags still override uniformly. The
   initial uniform `time: 3` setting was reverted after a stability
   pass (3 back-to-back runs) showed fast benchmarks at 4–55% CV
   purely because a 1-second OS spike could dominate a 60-200ms-
   per-iter measurement window.

   With per-benchmark times, NBody dropped from 4–6% CV to 0.2–0.7%
   when the system isn't loaded; the achievable noise floor in a
   noisy laptop environment is **median 2% / max ~7%** spread across
   re-runs. Coherent OS-level slowdowns affecting an entire run
   can't be fixed by longer measurement windows — those need a
   quiet machine.

2. **Per-version `MIX_BUILD_PATH`**: confirmed needed (a `.beam`
   compiled by OTP 27 won't load on OTP 28 reliably). The shell
   wrapper sets it; do we also want `mix awfy.measure` to refuse
   to run if `_build/dev/.compile.elixir` is from a different OTP
   version? Probably warn, not refuse — the user may have a reason.

15. **Aggregate metric for the suite-wide trend.** ✅ Decided:
    geometric mean of ratios. For each benchmark, compute
    `median_ms / baseline_median_ms`; take the geomean across all
    14. Default baseline is the most-recent loaded run, overridable
    with `--baseline LABEL`. Result is a dimensionless speedup
    factor — line trending downward over time means "performance
    went up," which is the question shape the dashboard exists to
    answer. Treats every benchmark equally regardless of absolute
    timing (a 50% Bounce speedup counts the same as a 50%
    DeltaBlue speedup), which is exactly what AWFY-style
    cross-benchmark comparison wants.

16. **X-axis ordering on the time-series charts.** ✅ Decided:
    in-page toggle, default timestamp order. Since the full
    dataset is embedded in the generated HTML (per Q7), re-sorting
    client-side is a `data.sort()` callback bound to a `<select>`
    in the filter UI. Two options exposed: timestamp (default,
    answers "over time") and parsed OTP version (answers "across
    OTP versions"). Multi-run-same-version cases tie-break on
    timestamp either way.

17. **Default visible series in the dashboard.** ✅ Decided: show
    everything on first paint, persist checkbox state to
    `localStorage` so subsequent visits remember the user's
    chosen filters. First-time users see the full dataset
    (discoverable); once a view is set up ("ARM JIT only across
    machines"), it sticks. Chart.js's legend natively supports
    click-to-toggle, so the legend itself is the filter UI for
    individual series; explicit checkboxes still exist for the
    coarser pivots (lang, machine, arch, emu_flavor) that group
    multiple series.

18. **Missing data points.** ✅ Decided:
    - **Per-benchmark chart**: render the gap with a `null` data
      point. Chart.js draws a break in the line; the label still
      appears on the X axis; hovering says "no data." Honest about
      what's missing without dropping the run from the chart.
    - **Suite-wide aggregate (index page)**: restrict the geomean
      to the *intersection* of benchmarks present in every loaded
      run. Apples-to-apples is the only correct way to compute a
      cross-run aggregate; mixing different denominators conflates
      "got faster" with "different benchmarks counted." A footer
      lists which benchmarks were dropped from the aggregate and
      which run(s) lacked them, so the rule is transparent.

3. **Layout of compare HTML.** ✅ Decided: per-benchmark pages plus
   an index, **with interactive time-series filtering** on every
   page. Each page must answer queries of the shape:

   - "Has overall performance gone up since OTP 25.3?"
     (suite-wide aggregate over time)
   - "Has ARM JIT performance gone up since 26.2?"
     (suite-wide aggregate, filter to arch=arm + emu_flavor=jit)
   - "Show Havlak performance on x86 vs ARM, JIT vs interpreter,
     over time" (one benchmark, four series)

   This rules out `benchee_html` as the per-page renderer —
   benchee_html shows within-run *distributions* (box plots,
   histograms), not across-run *time series*. We build a small
   single-page dashboard ourselves:

   - **Per-benchmark page**: time-series chart (X = label-ordered-
     by-timestamp, Y = median ms) with multiple selectable series
     for the {language × machine × arch × emu_flavor} pivot.
     Checkbox filter UI controls which series are visible.
   - **Index page**: same chart but the metric is a suite-wide
     aggregate across the visible benchmarks (see Q9 for which
     aggregate).

   Implementation:
   - `mix awfy.compare` loads every `meta.json` + `.benchee` save
     under `results/`, extracts a flat list of records
     `{timestamp, label, hostname, cpu, arch, emu_flavor, lang,
      benchmark, median_ms, mean_ms, stddev_ms, samples_n,
      inner_iter, source_sha256}` and embeds it as JSON inside the
     generated HTML.
   - Each page is a single static HTML file: dataset baked in,
     Chart.js loaded from CDN, ~150 lines of JS for filter UI +
     chart updates.
   - No server needed — the file works on `file://` open.

   Future: same JSON dataset can feed a `mix awfy.diff` (Q12) or
   a CLI summary, so the data extraction is the load-bearing
   piece, not the rendering.

4. **Tag collision.** ✅ Decided: warn and overwrite by default;
   `--no-clobber` flag refuses if the run-dir already exists.
   Re-running with the same label is almost always "redo, the
   first was bad" — overwriting is the right default. The
   stderr warning ("overwriting results/v1+otp28.4.1+...") makes
   the intent visible. `--no-clobber` exists for the rare case
   where preserving both runs matters; at that point the user
   should pick a more specific label.

5. **JSON sidecar.** ✅ Decided: skip until needed. CI integration
   is non-goal for v1; the dashboard reads `.benchee` saves
   directly. Adding `benchee_json` later is non-breaking — it
   just starts writing the new file alongside existing saves
   without touching any reader. Defer the decision to whoever
   first wants a CI perf-report workflow.

6. **Verification failure: fail-fast or partial save?** ✅ Decided:
   verify-pass before timing-pass. Run `inner_benchmark_loop(iter)`
   once per scenario first; skip any failing scenario in the
   Benchee timing pass and record `verified: false` for it in
   `meta.json`. Working scenarios still get saved. Clean separation
   between "is the port correct" and "how fast is it."

7. **Auto-label format.** ✅ Decided: SHA when clean, `SHA-dirty` +
   timestamp when uncommitted changes exist. Examples: `a1b2c3d`
   (clean) vs `a1b2c3d-dirty_2026-05-01T12-34` (dirty). Re-runs on
   the same clean commit overwrite (one canonical save per SHA);
   re-runs on a dirty tree accumulate (each is a different code
   state).

8. **Inner-iter mismatch in `compare`.** ✅ Decided: warn loudly and
   annotate. Render the chart but stamp the report header with the
   divergence ("v1 ran Bounce at iter=1500, v2 at iter=3000") and
   suffix each scenario name with its iter. User sees both the data
   and the disclaimer; nothing is silently rescaled or hidden.

8b. **Per-benchmark source hash in `meta.json`.** ✅ Decided: capture
    a SHA256 of each benchmark's source file when measuring, store
    in the per-benchmark entry of `meta.json`:

    ```json
    "benchmarks": [
      {
        "name": "Bounce",
        "erlang_source_sha256": "abc123...",
        "elixir_source_sha256": "def456...",
        "verified": {"erlang": true, "elixir": true}
      },
      ...
    ]
    ```

    Hash inputs: the benchmark's own source file only
    (`src/awfy_bounce.erl`, `lib/awfy/benchmarks/bounce.ex`). Shared
    utilities (`awfy_som_vector.erl`, `awfy_random.erl`, etc.) are
    *not* folded in — when they change, every benchmark's hash
    bumps simultaneously, which is itself a useful "this might be
    a wide change" signal in the compare report.

    `mix awfy.compare` reads hashes from each save's `meta.json`;
    if any benchmark's hash changed across loaded saves, surface in
    the report header ("Bounce source changed between v1 and v3 —
    perf delta may be code, not runtime"). Same warn-and-annotate
    pattern as the inner-iter mismatch.

9. **Machine mismatch in `compare`.** ✅ Decided: warn + annotate,
   same shape as Q8. Render the report, stamp the header with the
   divergence ("v1 on lukas-m5 / Apple M5, v2 on ci-runner-3 /
   Xeon E5-2680"), tag scenario names with the machine. Don't
   refuse — cross-machine compare is sometimes intentional, but
   never silent.

10. **Runtime flags worth capturing in `meta.json`.** ✅ Decided:
    curated `:erlang.system_info/1` set in `meta.json`. Captured:
    `:emu_flavor` (`:jit` vs `:emu`), `:schedulers_online`,
    `:logical_processors`, `:wordsize`, `:smp_support`,
    `:nif_version`, `:driver_version`, plus `mix_env` and
    `:erlang.system_flags/0`. Surfaces "you forgot `+JMsingle false`"
    silently-broken-comparison cases. `awfy.compare` displays
    mismatches as warnings in the report header.

11. **Result retention / pruning.** ✅ Decided: skip for v1. Run
    dirs are small (~200 KB each) and the dashboard's
    localStorage-persisted filters (Q17) cope with many series.
    Premature retention rules tend to delete the data you wanted
    right before you knew you wanted it — better to wait until a
    few months of real use makes the right policy obvious. Manual
    `rm -rf results/<dir>` covers the rare bad-run case in the
    meantime; `mix awfy.results.list` + `prune` slot in cleanly
    later as ~30 lines apiece.

12. **`mix awfy.diff label1 label2`.** ✅ Decided: build in Phase 3.
    Console-only command, ~50 lines, leans on the same data
    extraction as `awfy.compare`. Output is one line per benchmark
    showing both labels' median_ms and the percentage delta, with
    a `Geomean` row at the bottom answering "is this PR a
    regression overall?" Faster than opening a browser for the
    common iteration workflow ("did my last change regress
    anything?"). Same loader as `awfy.compare`, different
    formatter — low marginal cost.

13. **Data format versioning.** ✅ Decided: `"format_version": 1`
    field in `meta.json`. `mix awfy.compare` reads it; on mismatch,
    refuse with a clear error ("results/X is format v0, run a
    migration") instead of crashing inside JSON decode or pattern
    matching. One extra field's worth of cost now; clean error
    later when it inevitably matters.

14. **Benchee version pinning.** ✅ Decided: don't actively pin or
    record. The `.benchee` save format is `:erlang.term_to_binary`
    of Benchee's internal `Suite` struct, but cross-version mismatch
    is rare in practice and produces a recognizable decode/match
    error when it happens. If we hit a mid-stream Benchee upgrade
    that breaks old saves, deal with it then (re-measure, or write
    a one-off conversion). Not worth the extra plumbing now.
