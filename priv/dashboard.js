// SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
// SPDX-License-Identifier: Apache-2.0

/* AWFY dashboard — vanilla JS, no framework. */

const STORAGE_KEY = "awfy.filters." + PAGE_KIND + "." + BENCH_NAME;

// Within-benchmark series identifier:
//   * AWFY ports populate `lang` ("erlang" / "elixir") and leave
//     `input` null — series axis is the language port.
//   * OtpBenchmarks scenarios populate `input` ("atom",
//     "binary_4k", …) and leave `lang` null — series axis is the
//     input variant. The "Language" radio is overloaded to switch
//     between input variants on those pages.
// One field is always nil, so `lang || input` deterministically
// picks the populated one.
function seriesAxis(row) {
  return row.lang || row.input;
}

function seriesKey(row) {
  // Group by stable machine class (linux-x86_64 / macos-arm64 / …)
  // rather than ephemeral hostnames, so multi-CI runs collapse
  // into a single trend line per (axis × class × flavor).
  return [seriesAxis(row), row.machine_class, row.emu_flavor].join(" / ");
}

// Collapse OtpBenchmarks-shape rows (`input != null`) into a single
// synthetic row per (label, lang, machine_class, emu_flavor,
// benchmark, otp) whose `median_ms` is the geomean of the family's
// per-input medians. AWFY rows pass through unchanged. Used at the
// entry of suite-wide aggregations (trend chart geomean) so each
// multi-input family contributes one weighted-equally cell — without
// the fold, phash2's 13 cells would dominate the suite ratio against
// every AWFY benchmark's 1.
function foldMultiInputFamilies(rows) {
  const passthrough = [];
  const groups = {};

  rows.forEach(r => {
    if (!r.input) {
      passthrough.push(r);
      return;
    }
    const k = [r.label, r.lang, r.machine_class, r.emu_flavor, r.benchmark, r.otp].join("|");
    if (!groups[k]) groups[k] = [];
    groups[k].push(r);
  });

  const synthetic = Object.values(groups).map(rs => {
    // Geomean in log space — phash2 spans 12 ns to 6 µs, so
    // arithmetic mean would skew toward the slow inputs and lose
    // the boundary effects we want to track.
    const positive = rs.filter(r => typeof r.median_ms === "number" && r.median_ms > 0);
    if (positive.length === 0) return null;
    const sumLog = positive.reduce((s, r) => s + Math.log(r.median_ms), 0);
    const median = Math.exp(sumLog / positive.length);

    // Family-level synthetic row: clear input so downstream code
    // treats it like an AWFY single-cell row, override median,
    // zero stddev (per-input variance doesn't aggregate cleanly
    // into a per-family number — error bars on the suite chart
    // would lie about the family's confidence interval).
    return Object.assign({}, rs[0], {
      input: null,
      median_ms: median,
      stddev_ms: 0
    });
  }).filter(Boolean);

  return passthrough.concat(synthetic);
}

// Order OTP version strings: "20.0" < "20.1" < ... < "21.0" <
// ... < "28.5" < "maint" < "master". Compares dotted-numeric
// components pairwise; "maint" and "master" sort after everything
// numeric so the floating tips land at the right edge of the chart.
function compareOtpVersions(a, b) {
  if (a === b) return 0;
  if (a === "master") return 1;
  if (b === "master") return -1;
  if (a === "maint")  return 1;
  if (b === "maint")  return -1;
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
  catch (_e) { /* localStorage disabled or quota exceeded — ignore */ }
}

/* ---- Filter state (tabs + radio + checkboxes) ----------------------
   The control shapes differ by page:
   - Suite page: machine class is a tab strip (single-select) so the
     headline geomean stays one platform at a time; language is a
     checkbox group because seeing erlang and elixir together on the
     snapshot bars is the point.
   - Per-bench page: machine class is a checkbox group so a single
     benchmark can be compared across platforms on one chart;
     language is a radio because mixing erlang+elixir lines for
     multiple platforms on one canvas turns into a thicket.
   Flavor stays as a radio everywhere (jit vs emu run different code
   paths; overlaying them is rarely what you want).
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

// Per-bench machine_class control: same DOM slot as the suite page's
// tab strip but rendered as a Platform checkbox group so a single
// benchmark can show multiple platforms on one chart. Sheds the
// .tabs styling so it lays out like the rest of the controls row.
function buildPlatformCheckboxes(values, persisted, fallbacks) {
  const container = document.getElementById("machine-tabs");
  container.classList.remove("tabs");
  container.classList.add("controls", "platform-controls");
  const group = document.createElement("div");
  group.className = "group";
  const heading = document.createElement("b");
  heading.textContent = "Platform";
  group.appendChild(heading);
  // Tolerate stale persisted state from before this control was a
  // multi-select — fall back to the default platform set if so.
  const persistedArr = Array.isArray(persisted) ? persisted : null;
  const defaults = Array.isArray(fallbacks) ? fallbacks : [fallbacks];
  values.forEach(v => {
    const lab = document.createElement("label");
    const inp = document.createElement("input");
    inp.type = "checkbox";
    inp.name = "machine";
    inp.value = v;
    inp.checked = persistedArr ? persistedArr.includes(v) : defaults.includes(v);
    inp.addEventListener("change", onFilterChange);
    lab.appendChild(inp);
    lab.appendChild(document.createTextNode(" " + v));
    group.appendChild(lab);
  });
  container.appendChild(group);
}

// Multi-select checkbox group rendered into #control-lang on
// per-bench pages whose family has multiple input variants
// (OtpBenchmarks scenarios). Replaces the single-select
// "Language" radio so every input renders concurrently on the
// chart by default; individual inputs can be hidden via uncheck
// for a focused view. The control's <input>s share the `name="lang"`
// attribute so the existing applyFilters / readUIState shape
// (array-of-values lang state) flows unchanged — `lang` here means
// "within-benchmark series axis", overloaded for OtpBenchmarks
// just as it's overloaded in the data row's `seriesAxis()` helper.
function buildInputCheckboxes(values, persisted) {
  const container = document.getElementById("control-lang");
  // Replace the static <b>Language</b> heading and any prior
  // radio buttons that the static template emitted.
  container.innerHTML = "";
  const heading = document.createElement("b");
  heading.textContent = "Input";
  container.appendChild(heading);

  const persistedArr = Array.isArray(persisted) ? persisted : null;
  values.forEach(v => {
    const lab = document.createElement("label");
    const inp = document.createElement("input");
    inp.type = "checkbox";
    inp.name = "lang";
    inp.value = v;
    // Default: every input checked. Persisted state overrides if
    // present so an unchecked-on-last-visit input stays hidden
    // across reloads.
    inp.checked = persistedArr ? persistedArr.includes(v) : true;
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
  const flavor = (document.querySelector('input[name="flavor"]:checked') || {}).value;
  // The lang/series-axis control is a single-select radio on AWFY
  // pages and a multi-select checkbox group on multi-input
  // OtpBenchmarks pages. Detect by the rendered <input> type and
  // shape state.lang accordingly — applyFilters already handles
  // both array (any-of) and scalar (equals) shapes via seriesAxis.
  const langInputs = document.querySelectorAll('input[name="lang"]');
  const isCheckboxLang = langInputs.length > 0 && langInputs[0].type === "checkbox";
  const lang = isCheckboxLang
    ? [...langInputs].filter(i => i.checked).map(i => i.value)
    : (document.querySelector('input[name="lang"]:checked') || {}).value;
  if (PAGE_KIND === "bench") {
    return {
      machine_class: [...document.querySelectorAll('input[name="machine"]:checked')].map(c => c.value),
      emu_flavor: flavor,
      lang
    };
  }
  const activeTab = document.querySelector("#machine-tabs .tab.active");
  return {
    machine_class: activeTab ? activeTab.dataset.value : null,
    emu_flavor: flavor,
    lang
  };
}

function applyFilters(rows, state) {
  const langOK = Array.isArray(state.lang)
    ? (r) => state.lang.includes(seriesAxis(r))
    : (r) => seriesAxis(r) === state.lang;
  const mcOK = Array.isArray(state.machine_class)
    ? (r) => state.machine_class.includes(r.machine_class)
    : (r) => r.machine_class === state.machine_class;
  return rows.filter(r => langOK(r) && mcOK(r) && r.emu_flavor === state.emu_flavor);
}

/* Build series: group rows by (lang, machine, arch, emu_flavor).
   Per-bench page only — y values are baseline_ms / current_ms so
   higher = faster than the earliest run for that series, matching
   the suite chart's "× over baseline" framing. Whisker bounds
   map cleanly: ymin/ymax in ms invert to baseline/(ms+2σ) and
   baseline/(ms-2σ) respectively. (Absolute ms isn't a useful
   cross-platform y axis — different CPUs run at different speeds,
   so platforms with slower hardware would dominate the visual
   range and obscure the speedup trend.)
*/
function buildSeries(rows, xAxis) {
  const groups = {};
  rows.forEach(row => {
    const key = seriesKey(row);
    if (!groups[key]) groups[key] = [];
    groups[key].push(row);
  });

  const xKey = xAxis === "otp" ? "otp" : "timestamp";

  return Object.entries(groups).map(([_key, items]) => {
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
      // Suite page has a single machine_class via the tab strip, so
      // the only thing that varies between series is the language
      // — label by lang. Per-bench page picks the language with a
      // radio and the platforms with checkboxes, so machine_class
      // is what varies — label by that instead.
      // Series label is the field that *varies* between series:
      //   * Suite page: lang varies, machine_class is fixed by tab.
      //   * AWFY per-bench page: machine_class varies (multi-select),
      //     lang is fixed by radio.
      //   * Multi-input per-bench page: input varies (multi-select),
      //     machine_class is the per-bench multi-select but for
      //     OtpBenchmarks we render input as the primary distinction
      //     so user sees "atom" / "binary_4k" / … not "macos-arm64".
      label:
        items[0].input ||
        (PAGE_KIND === "bench" ? items[0].machine_class : items[0].lang),
      data: sorted.map(r => {
        const x = xAxis === "otp" ? r.otp : Date.parse(r.timestamp);
        const ratio = (baseMs && r.median_ms) ? baseMs / r.median_ms : null;
        // Cap 2σ at half the median for whisker math. Sub-µs
        // benchmarks routinely show CV ≥ 50% (clock-floor noise),
        // and the unbounded form `baseMs / (median - 2σ)` blows up
        // toward Infinity as 2σ approaches median — a single such
        // point dominates the chart's y range and crushes every
        // other series. Capping at median/2 means a noisy point's
        // upper whisker goes no higher than 2× the ratio, which
        // keeps the chart readable while still telegraphing
        // uncertainty (a tall whisker still says "noisy"; it just
        // doesn't say "literally infinite"). Lower whisker is
        // symmetric — yMin uses the same capped sigma.
        const rawSigma = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
        const sigma = (r.median_ms && rawSigma > r.median_ms / 2) ? r.median_ms / 2 : rawSigma;
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
  // Multi-input families (OtpBenchmarks scenarios where `input` is
  // populated) collapse into one synthetic per-family cell whose
  // median is the geomean across the family's input cells —
  // weighted equally with each AWFY benchmark in the suite-wide
  // ratio. Without the fold, phash2's 13 cells would dominate the
  // geomean against any AWFY 1-cell benchmark; mirrors the Elixir
  // `Awfy.Compare.Data.geomean_ratio/2` policy.
  const rows = foldMultiInputFamilies(
    DATASET.rows.filter(r => r.emu_flavor === "jit")
  );

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

  // For the combined "all platforms" line we group by
  // function-release bucket ("23.3" for both "23.3.4.20" and
  // "23.3") rather than exact OTP version — older Windows builds
  // only ship installers at the function-release granularity
  // ("OTP-23.3"), while macos/linux build the patch tip
  // ("OTP-23.3.4.20"). Without bucketing they'd never share an
  // x position and the all-platforms line would be empty for the
  // entire OTP-21/22/23 range. From OTP-24 on every platform
  // builds the same exact patch versions, so the bucket and the
  // exact OTP coincide and bucketing is a no-op there.
  function bucketFor(otp) {
    if (otp === "master" || otp === "maint") return otp;
    const parts = String(otp).split(".");
    // Bare-major labels like "26" canonicalise to "26.0" so they
    // bucket with "26.0.2", "26.1.2", etc.
    if (parts.length === 1) return parts[0] + ".0";
    return parts[0] + "." + parts[1];
  }
  const compareBuckets = (a, b) => {
    if (a === b) return 0;
    if (a === "master") return 1; if (b === "master") return -1;
    if (a === "maint")  return 1; if (b === "maint")  return -1;
    return compareOtpVersions(a, b);
  };

  // Per-platform within each bucket: pick the most-specific (lex
  // newest) OTP that platform has. Linux usually sees both "23.3"
  // and "23.3.4.20" in the dataset right now — using only the
  // newest keeps a single canonical row per platform per bucket
  // so geomeans aren't double-counting.
  const canonByMcBucket = {};
  rows.forEach(r => {
    const otp = runOtp[r.label];
    if (!otp) return;
    const b = bucketFor(otp);
    if (!canonByMcBucket[r.machine_class]) canonByMcBucket[r.machine_class] = {};
    const cur = canonByMcBucket[r.machine_class][b];
    if (!cur || compareOtpVersions(otp, cur) > 0) {
      canonByMcBucket[r.machine_class][b] = otp;
    }
  });
  const mcs = Object.keys(canonByMcBucket);

  // Pin for the combined line: earliest function-release bucket
  // present on every platform. With windows's "23.3"-style labels
  // bucketed alongside macos/linux's "23.3.4.20" labels, this
  // intersection picks up the OTP-21/22/23 range that the
  // exact-OTP intersection used to skip entirely.
  const bucketsByMc = {};
  mcs.forEach(mc => {
    bucketsByMc[mc] = new Set(Object.keys(canonByMcBucket[mc]));
  });
  let commonBuckets = mcs.length ? [...bucketsByMc[mcs[0]]] : [];
  for (let i = 1; i < mcs.length; i++) {
    commonBuckets = commonBuckets.filter(b => bucketsByMc[mcs[i]].has(b));
  }
  commonBuckets.sort(compareBuckets);
  const pinnedBucket = commonBuckets[0] || null;

  // Combined-line baseline: per (lang, machine_class, benchmark),
  // the median at that platform's *canonical* OTP for the pinned
  // bucket — windows uses its "23.3" row, linux/macos use their
  // "23.3.4.20" row, all anchored to the same OTP-23.3
  // function-release. Earliest timestamp on tiebreak (re-runs).
  const pinnedBaseIdx = {};
  if (pinnedBucket) {
    rows.forEach(r => {
      const otp = runOtp[r.label];
      if (!otp) return;
      const canon = canonByMcBucket[r.machine_class][pinnedBucket];
      if (otp !== canon) return;
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

  // Combined line: bucket by function-release; per-platform we
  // only consume that platform's canonical (most-specific) OTP
  // for each bucket so platforms with redundant rows in the
  // dataset don't double-contribute. Plot the resulting point at
  // the lex-newest canonical OTP across platforms — i.e. the
  // "23.3.4.20" tick when linux/macos are on the patch tip and
  // windows is on the bare "23.3", so the all-platforms marker
  // visually coincides with linux/macos's per-platform markers.
  // Skip any bucket where not every platform contributed: a
  // single-platform geomean masquerading as cross-platform
  // would be misleading.
  const allByBucket = {};
  const allMcsAtBucket = {};
  const xLabelByBucket = {};
  if (pinnedBucket) {
    rows.forEach(r => {
      const otp = runOtp[r.label];
      if (!otp || !r.median_ms) return;
      const b = bucketFor(otp);
      if (compareBuckets(b, pinnedBucket) < 0) return;
      if (otp !== canonByMcBucket[r.machine_class][b]) return;
      const bk = r.lang + "|" + r.machine_class + "|" + r.benchmark;
      const base = pinnedBaseIdx[bk];
      if (!base || !base.ms) return;
      const ratio = base.ms / r.median_ms;
      if (!allByBucket[b]) allByBucket[b] = [];
      allByBucket[b].push(ratio);
      if (!allMcsAtBucket[b]) allMcsAtBucket[b] = new Set();
      allMcsAtBucket[b].add(r.machine_class);
      if (!xLabelByBucket[b] || compareOtpVersions(otp, xLabelByBucket[b]) > 0) {
        xLabelByBucket[b] = otp;
      }
    });
    const numMcs = mcs.length;
    for (const b of Object.keys(allByBucket)) {
      if ((allMcsAtBucket[b] && allMcsAtBucket[b].size) !== numMcs) {
        delete allByBucket[b];
        delete xLabelByBucket[b];
      }
    }
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

  const allSeries = pinnedBucket ? {
    label: "all platforms",
    data: Object.entries(allByBucket)
      .map(([b, ratios]) => ({
        x: xLabelByBucket[b],
        y: geomean(ratios),
        n_benchmarks: ratios.length,
        pinnedOtp: xLabelByBucket[pinnedBucket]
      }))
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

// Map every OTP label in the visible series to a numeric x position
// where each OTP major occupies a width of 1 on the axis. See
// renderChart() for the pixel-spacing rationale. Also returns the
// list of numeric majors and master/maint flags so the scale config
// can pick min/max and tick labels.
function buildOtpXMap(otpLabels) {
  const labelsByMajor = {};
  otpLabels.forEach(l => {
    const m = (l === "master" || l === "maint") ? l : String(l).split(".")[0];
    if (!labelsByMajor[m]) labelsByMajor[m] = [];
    labelsByMajor[m].push(l);
  });
  Object.values(labelsByMajor).forEach(arr => arr.sort(compareOtpVersions));

  const numericMajors = Object.keys(labelsByMajor)
    .filter(m => m !== "master" && m !== "maint")
    .map(s => parseInt(s, 10))
    .filter(n => !Number.isNaN(n))
    .sort((a, b) => a - b);

  const map = {};
  numericMajors.forEach(m => {
    const arr = labelsByMajor[String(m)];
    arr.forEach((l, i) => { map[l] = m + (i / arr.length); });
  });

  const maxNumeric = numericMajors.length ? numericMajors[numericMajors.length - 1] : 0;
  const hasMaint = !!labelsByMajor.maint;
  const hasMaster = !!labelsByMajor.master;
  // maint and master each occupy the next integer slot after the
  // highest released major — consecutively, no gaps. So with master
  // and no maint, master is at maxNumeric+1 (right next to 29);
  // with both, maint is at +1 and master at +2.
  const maintX = maxNumeric + 1;
  const masterX = maxNumeric + (hasMaint ? 2 : 1);
  if (hasMaint) {
    const arr = labelsByMajor.maint;
    arr.forEach((l, i) => { map[l] = maintX + (i / arr.length); });
  }
  if (hasMaster) {
    const arr = labelsByMajor.master;
    arr.forEach((l, i) => { map[l] = masterX + (i / arr.length); });
  }

  return { map, numericMajors, maxNumeric, hasMaint, hasMaster, maintX, masterX };
}

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
  // visible series, then remap each datum's `x` from a string
  // version label ("21.0.9") to a numeric position so the chart's
  // x scale can be linear. Each OTP major occupies a width of 1 on
  // the axis: data points within a major are subdivided as
  // `major + rank/count`, where rank is the within-major index
  // under compareOtpVersions ordering. Without this remap the
  // category scale gives every label equal pixel width — so a
  // major with 1 point ("20.3") visibly squeezes against a major
  // with 9 points ("21.0.9, 21.1.4, ..."), which makes the OTP-21
  // → OTP-22 jump look proportionally larger than the OTP-20 →
  // OTP-21 jump even though they're each one major. master/maint
  // get their own integer slots past the highest released major.
  const otpLabels = xAxis === "otp"
    ? [...new Set(series.flatMap(s => s.data.map(d => d.x)))].sort(compareOtpVersions)
    : null;
  const otpXInfo = otpLabels ? buildOtpXMap(otpLabels) : null;
  if (otpXInfo) {
    series.forEach(s => {
      s.data.forEach(d => {
        d.otpLabel = d.x;
        d.x = otpXInfo.map[d.x];
      });
      // The series builders sort by compareOtpVersions on the raw
      // labels — that ordering is monotonic in our numeric x too
      // (within-major rank is preserved, majors increment cleanly),
      // so we don't need to re-sort here.
    });
  }

  if (chart) chart.destroy();
  chart = new Chart(document.getElementById("chart"), {
    type: chartType,
    data: { datasets },
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
              // Linear axis where each OTP major is one unit wide,
              // so 20→21 and 27→28 take the same horizontal space
              // regardless of how many sub-versions populate each.
              // Sub-versions within a major (20.3, 21.0, 21.0.9,
              // 21.1, …) get fractional positions inside [major,
              // major+1) via the rank/count formula in
              // buildOtpXMap. master sits at maxMajor+2, maint at
              // maxMajor+1; we put a labelled tick at each
              // numeric-major position plus master/maint when
              // present.
              type: "linear",
              min: otpXInfo.numericMajors.length ? otpXInfo.numericMajors[0] : 0,
              max: otpXInfo.hasMaster ? otpXInfo.masterX
                  : otpXInfo.hasMaint  ? otpXInfo.maintX
                  : otpXInfo.maxNumeric,
              title: { display: true, text: "OTP version", font: titleFont },
              ticks: {
                font: tickFont,
                stepSize: 1,
                autoSkip: false,
                maxRotation: 0,
                callback: function(value) {
                  const v = Math.round(value);
                  if (otpXInfo.hasMaster && v === otpXInfo.masterX) return "master";
                  if (otpXInfo.hasMaint  && v === otpXInfo.maintX)  return "maint";
                  if (otpXInfo.numericMajors.indexOf(v) !== -1) return String(v);
                  return "";
                }
              },
              grid: { color: "#eee" }
            },
        y: {
          // Logarithmic — speedups are inherently multiplicative,
          // and the OtpBenchmarks families covering a decade of OTP
          // optimizations span 30×+ in some cases (base64 encode_n64k
          // went 3.5 ms → 0.1 ms between OTP-20 and OTP-28). Linear
          // scale would crush the early-OTP curve into a flat line at
          // the bottom, hiding everything below ~3×. Log lays the
          // 1× line at the visual midline with symmetric headroom
          // for slowdowns and speedups. Ratios are always positive
          // in our data prep (yMin/yMax guard against zero), so log
          // is safe.
          type: "logarithmic",
          title: { display: true, text: yLabel, font: titleFont },
          ticks: {
            font: tickFont,
            // Auto-tick on log scale otherwise emits 0.1, 1, 10 only,
            // which loses resolution in the 0.5×–3× range that holds
            // most measurements. Format every tick the scale draws —
            // chart.js picks 1-2-5 multiples per decade — so e.g.
            // 0.5, 1, 2, 5, 10, 20 get drawn explicitly.
            callback: function(v) {
              return Number(v.toFixed(2)).toString() + "×";
            }
          },
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
              if (xAxis === "otp") return "OTP " + (r.otpLabel || r.x);
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

  // One headline line per series-axis value. AWFY pages: one per
  // language ("erlang", "elixir"). Multi-input pages: one per
  // checked input ("atom", "binary_4k", …) — `seriesAxis` collapses
  // to whichever of lang/input is populated.
  const labels = [...new Set(filtered.map(seriesAxis))].sort();
  const lines = labels.map(label => {
    // For each (series-axis-value, benchmark) pick the latest run on each end.
    const pickLatest = (otp) => {
      const m = {};
      filtered.filter(r => seriesAxis(r) === label && r.otp === otp).forEach(r => {
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
    return { lang: label, speedup, benches };
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
      ? "all platforms for " + BENCH_NAME
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
        // Same noise-floor cap as the line chart's whisker math:
        // bound 2σ at median/2 so a single high-CV bar can't push
        // its yMax to ~Infinity and stretch the chart's y-axis.
        const rawSigma = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
        const sigma = rawSigma > r.median_ms / 2 ? r.median_ms / 2 : rawSigma;
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
          // Same logarithmic rationale as the line chart above —
          // bars are speedup ratios (`baseline / median`), and a
          // 30× bar in base64/encode_n64k otherwise crushes every
          // bar between 1×–3× into a flat strip near the x axis.
          type: "logarithmic",
          title: { display: true, text: "speedup × over baseline (log scale)", font: titleFont },
          ticks: {
            font: tickFont,
            callback: function(v) {
              return Number(v.toFixed(2)).toString() + "×";
            }
          },
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
// Guarded so the file can be required from Node (test runner) without
// crashing on `document.getElementById` — the helpers above are pure
// and re-exported via module.exports at the bottom of the file.
if (typeof document !== "undefined") (function () {
  const state = loadFilterState();
  const machineClasses = uniqueValues(DATASET.rows, "machine_class");
  const flavors = uniqueValues(DATASET.rows, "emu_flavor");
  // Defaults: JIT + Erlang everywhere. Per-bench gets both Linux
  // platforms checked by default so a fresh visit shows the
  // cross-platform comparison the multi-select control was built
  // for; suite stays single-platform on the linux-x86_64 tab.
  buildRadioGroup("control-flavor", "flavor", flavors, state.emu_flavor, "jit");

  // Within-benchmark control. Two shapes:
  //   * AWFY-shape page (rows have `lang` set, `input` null) →
  //     single-select "Language" radio with ["elixir", "erlang"].
  //   * OtpBenchmarks-shape page (rows have `input` set, `lang`
  //     null) → multi-select "Input" checkboxes, default all
  //     checked so every input variant renders concurrently.
  // Suite-index pages always use the radio: multi-input rows have
  // lang=null and are dropped by applyFilters / suite-geomean
  // anyway, so the radio cleanly lists only AWFY ports.
  const isMultiInput =
    PAGE_KIND === "bench" && DATASET.rows.some(r => r.input);
  if (isMultiInput) {
    const inputs = [...new Set(DATASET.rows.map(r => r.input).filter(Boolean))].sort();
    const persistedInputs = Array.isArray(state.lang) ? state.lang : null;
    buildInputCheckboxes(inputs, persistedInputs);
  } else {
    const langs = uniqueValues(DATASET.rows, "lang");
    // Persisted lang state may be an array (from a previous
    // multi-input visit on the same STORAGE_KEY) or a scalar.
    // Collapse to the first element so the AWFY radio doesn't
    // crash when handed an array.
    const persistedLang = Array.isArray(state.lang) ? state.lang[0] : state.lang;
    buildRadioGroup("control-lang", "lang", langs, persistedLang, "erlang");
  }
  if (PAGE_KIND === "bench") {
    buildPlatformCheckboxes(machineClasses, state.machine_class,
      ["linux-arm64", "linux-x86_64"]);
  } else {
    buildTabs(machineClasses, state.machine_class, "linux-x86_64");
  }
  // The major-checkboxes container is only on the suite page;
  // skip on per-bench pages where the snapshot doesn't render.
  if (PAGE_KIND === "suite") {
    buildSnapshotMajorCheckboxes();
  }

  // Reset wipes this page's filter state and reloads. Per-page
  // STORAGE_KEY scoping means the index reset doesn't disturb
  // any per-bench page's selections, and vice versa.
  document.getElementById("reset-filters").addEventListener("click", () => {
    try { localStorage.removeItem(STORAGE_KEY); } catch (_e) { /* ignore */ }
    location.reload();
  });

  renderRunsMeta();
  renderAll();
})();

// Re-export the pure helpers for the Vitest test suite. Browsers
// don't define `module`, so the typeof guard keeps this a no-op
// in production. Eslint's browser config doesn't know about the
// CommonJS `module` global — eslint.config.js whitelists it.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    compareOtpVersions,
    majorOf,
    seriesAxis,
    seriesKey,
    foldMultiInputFamilies,
    applyFilters,
    buildOtpXMap,
    buildSeries,
    defaultMajorsSet
  };
}
