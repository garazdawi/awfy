# Dashboard — Requirements

The dashboard is the user-facing surface of AWFY. It must let a
visitor land on a page, immediately see whether OTP is faster or
slower than a meaningful baseline, and drill down to the data
behind that judgement.

See also: [Benchmarks](benchmarks.md), [Measurement](measurement.md).

## Pages

The dashboard shall expose three page kinds, all rendered by
`mix awfy.compare --out _pages`:

1. **Suite chart** (`index.html`, `PAGE_KIND === "suite"`) — the
   landing page. OTP-axis x, geomean speedup y, one series per
   benchmark + thick aggregate per (platform, flavor).
2. **Master timeline** (`master.html`, `PAGE_KIND === "master"`) —
   per-merge view. Time-axis x, geomean speedup y, one series per
   (platform, flavor) plus a bold all-platforms aggregate.
3. **Per-benchmark** (`per-bench/<name>.html`, `PAGE_KIND ===
   "bench"`) — one chart per AWFY benchmark / OtpBenchmarks family,
   linked from the suite chart's drill-down.

Pages shall render purely from JSON dataset embedded at build time
(no runtime data fetch). The static site assumption (no backend)
holds.

## Baseline

All speedup numbers shall be ratios against the **full-history
baseline**, which is the earliest OTP version with a measurement
for the same (lang, machine_class, benchmark) cell. In practice
that's `OTP-20.3` for synthetic + OtpBenchmarks suites.

- The baseline is **not** the earliest visible point. Filtering
  the chart to a narrower OTP range must not re-anchor the y-axis.
- The master timeline pre-computes the per-(platform, sha) speedup
  server-side and stores it as `master_y`; the JS uses that
  directly so the OTP-29.0 number on master.html equals the
  OTP-29.0 number on the suite chart.

Adding new historical data earlier than the current baseline (e.g.
measuring OTP-19) would re-anchor every speedup. That's a
deliberate one-off operation, not a routine fill output.

## JIT cutoff

Per-platform JIT cutoffs (see [Platforms](platforms.md)) shall be
applied at *render* time, not measurement time:

- A measurement may collect both `jit` + `emu` flavors per (sha,
  platform).
- The chart shows only one flavor per (platform, OTP) cell — the
  flavor that matches the platform's BeamAsm availability at that
  OTP version.

The master/maint refs are always treated as JIT-eligible.

## OtpBenchmarks per-input fold

OtpBenchmarks families with multiple inputs (e.g. `phash2` runs 13
different input shapes) shall be folded to a single geomean per
family before contributing to the suite-wide geomean. Without this
fold a 13-input family would weigh 13× a single-cell AWFY
benchmark in the geomean.

`mix awfy.compare`'s `fold_multi_input_families/1` and
dashboard.js's `foldMultiInputFamilies` shall stay consistent — a
divergence between server-side fold and client-side fold drifts
the master timeline value from the suite chart value.

## Suite chart specifics

The suite chart shall:

- Default to one platform tab + one flavor radio (machine class +
  emu_flavor selectors).
- Show error bars (toggle) computed as ±2σ of per-iteration
  timings, capped at half the median so a single noisy point can't
  push yMax toward infinity.
- Drill down on a clicked point to the per-benchmark page.

## Master timeline specifics

The master timeline shall:

- Anchor on `OTP-29.0` visually (left edge of the visible chart),
  but compute speedups against the full-history baseline so the
  29.0 number matches the suite chart.
- Show a rolling **3-month** window of master merges. Older
  measurements remain on gh-pages but drop out of the timeline
  view.
- Plot one series per (platform, flavor) + one bold all-platforms
  aggregate.
- Have no platform-tab / flavor-radio / error-bars controls — it's
  a single static view.
- On click, pin a drill card showing:
  - Short SHA + commit subject.
  - PR link (handles both master-aimed PRs and maint→master
    forward-merges via "Merge branch 'maint'" parent-walk).
  - Per-benchmark medians at that commit.
- Pinned drill cards shall share a single horizontal bar chart for
  cross-pin per-benchmark comparison (not a chart per card).
- When the user tries to pin a card from a different platform than
  the existing pins, show a confirmation modal with Cancel /
  Add+Clear / Add buttons (mixing platforms in one chart is
  legitimate but easy to misread).

## Per-benchmark page

The per-benchmark page shall:

- Show OTP-axis with all platforms + flavors, since this is the
  drill-down view (no filter constraints).
- Show measurement count `samples_n` per cell so a low-sample run
  is visibly less trustworthy than a high-sample one.
- Surface input variants for OtpBenchmarks families (one line per
  input).

## Headline metric

Each page shall show a small headline above the chart with the
"point of interest" reading:

- **Suite chart:** "Latest OTP-X.Y is N× faster/slower than
  baseline" where N is the latest OTP version's all-platforms
  geomean speedup.
- **Master timeline:** "Master tip is N× the OTP-29.0 number"
  derived from `latest.master_y / anchor.master_y` (so the
  headline is consistent with the chart).
- **Per-bench:** "Latest OTP-X.Y at <platform-flavor> is N× the
  baseline" for the highest-cell-count platform.

When fewer than two comparable points exist, the headline shall
say so explicitly (not silently render 1.0×).

## What the dashboard must not do

- Must not re-anchor the y-axis on filter change.
- Must not show a "1.0×" when no comparison is possible — render a
  visible "no comparison available" message instead.
- Must not silently drop measurements that fail to parse — print
  to console + count toward a "data quality" footer.
- Must not depend on runtime services (no API calls, no CDN
  required for data, no fonts that gate the chart).
