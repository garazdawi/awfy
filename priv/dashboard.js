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
  // readUIState only reads the controls owned by this function
  // (platform tab / flavor / lang / whiskers). Merge into the
  // persisted state so fields the snapshot-major checkboxes and
  // the machine-specs toggle persist there don't get clobbered.
  const persisted = loadFilterState();
  const fresh = readUIState();
  saveFilterState({ ...persisted, ...fresh });
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
  // Whiskers default on; toggle persists across reloads. The
  // checkbox lives in #control-display and is rendered server-side
  // already-checked, so an unset state means "show".
  const whiskerEl = document.getElementById("show-whiskers");
  const show_whiskers = whiskerEl ? whiskerEl.checked : true;
  if (PAGE_KIND === "bench") {
    return {
      machine_class: [...document.querySelectorAll('input[name="machine"]:checked')].map(c => c.value),
      emu_flavor: flavor,
      lang,
      show_whiskers
    };
  }
  const activeTab = document.querySelector("#machine-tabs .tab.active");
  return {
    machine_class: activeTab ? activeTab.dataset.value : null,
    emu_flavor: flavor,
    lang,
    show_whiskers
  };
}

function applyFilters(rows, state) {
  // Master page rows have already been server-side filtered + flavor-
  // cutoff-resolved + aggregated; the controls (tabs, flavor radio,
  // error-bars checkbox) aren't rendered on master.html so state's
  // fields are undefined. Pass through.
  if (PAGE_KIND === "master") return rows;

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
// `showWhiskers` lets the caller suppress yMin/yMax — unchecking
// the Display→Error bars toggle. Defaults to true so existing
// callers (tests, internal callers without state) keep their
// historical behavior.
function buildSeries(rows, xAxis, showWhiskers) {
  if (showWhiskers === undefined) showWhiskers = true;
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
        (PAGE_KIND === "bench" || PAGE_KIND === "master"
          ? items[0].machine_class + " / " + items[0].emu_flavor
          : items[0].lang),
      data: sorted.map(r => {
        const x = xAxis === "otp" ? r.otp : Date.parse(r.timestamp);
        // Master timeline pre-computes the y server-side
        // (master_y = speedup vs the full-history baseline, e.g.
        // OTP-20.3) so the number matches the main suite chart's
        // OTP-29.0 cell. Without this override buildSeries would
        // ratio against the earliest VISIBLE point (OTP-29.0 in
        // the 3-month window) and the y would collapse to ~1.0×.
        const ratio = (typeof r.master_y === "number")
          ? r.master_y
          : ((baseMs && r.median_ms) ? baseMs / r.median_ms : null);
        // Whisker = ±2σ of per-iteration timings, capped at half
        // the median. σ tells the story we want — "this benchmark
        // has high spread per iteration" — and stays visible across
        // sample counts. (We tried SE = σ/√N, which is the right
        // statistic for "how confident are we in *this* median",
        // but at our typical N≥10⁴ the SE-derived whisker collapses
        // to sub-pixel and the chart looks like there's zero
        // uncertainty anywhere. Visible noise indication beats
        // statistical purity for this view.)
        // Cap kicks in when 2σ ≥ median/2 (CV ≥ 25%): keeps the
        // upper whisker bounded at 2× the ratio so a single noisy
        // point can't push yMax toward Infinity.
        const rawHalf = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
        const half = (r.median_ms && rawHalf > r.median_ms / 2) ? r.median_ms / 2 : rawHalf;
        const yMax = (baseMs && r.median_ms - half > 0) ? baseMs / (r.median_ms - half) : ratio;
        const yMin = (baseMs && r.median_ms + half > 0) ? baseMs / (r.median_ms + half) : ratio;
        return {
          x,
          y: ratio,
          // null yMin/yMax tells lineWithErrorBars to skip drawing
          // the whisker — that's what the Display→Error bars toggle
          // requests. y itself stays so the line still renders.
          yMin: showWhiskers ? yMin : null,
          yMax: showWhiskers ? yMax : null,
          median_ms: r.median_ms,
          stddev: r.stddev_ms,
          run_label: r.label,
          inner_iter: r.inner_iter,
          base_ms: baseMs,
          // Per-second sample series for application benchmarks
          // (XMPP cpu/mem/speed). Drives the onClick comparison
          // panel below the chart. Null for synthetic benchmarks.
          samples: r.samples || null,
          samples_unit: r.samples_unit || "",
          // Master-timeline drill-down fields (master.html only).
          // otp_tag is "OTP-X.Y.Z" for tagged maint-tip points,
          // null for master merges. run_sha + bench_details power
          // the click drill-down's PR lookup + per-bench table.
          otp_tag: r.otp_tag || null,
          run_sha: r.run_sha || null,
          bench_details: r.bench_details || null,
          otp_for_panel: r.otp,
          machine_class_for_panel: r.machine_class,
          flavor_for_panel: r.emu_flavor
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
  const runOtp = {};
  DATASET.runs.forEach(r => { runOtp[r.label] = r.otp; });

  // BeamAsm JIT was added in OTP 24. Pre-24 has no JIT data
  // anywhere, so per-platform lines and the all-platforms line
  // fall back to emu rows for OTP < 24 and use jit rows from
  // 24 onwards. Each per-platform line ends up anchored at that
  // platform's own earliest OTP (typically 20.3 for linux/macos,
  // 24.0 for windows which has no legacy bundle path).
  function rowOtpMajor(r) {
    const otp = runOtp[r.label];
    if (!otp) return null;
    if (otp === "master" || otp === "maint") return Infinity;
    const m = parseInt(String(otp).split(".")[0], 10);
    return Number.isFinite(m) ? m : null;
  }
  const rows = foldMultiInputFamilies(
    DATASET.rows.filter(r => {
      const major = rowOtpMajor(r);
      if (major === null) return false;
      return major >= 24 ? r.emu_flavor === "jit" : r.emu_flavor === "emu";
    })
  );

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
  //
  // Include any bucket where at least one platform contributed.
  // The line is labelled "all platforms" but is really "platforms
  // we have data for at this bucket" — the tooltip's
  // n_benchmarks and platforms list expose the depth.
  //
  // Equal per-platform weighting: collect each platform's ratios
  // separately, geomean those per-platform, then geomean across
  // platforms. Without this fold, macos's 108 OtpBenchmarks
  // scenarios dominate the bucket against linux/windows's 28
  // AWFY-only scenarios and the combined line just tracks macos.
  //
  // Pre-24 / post-24 flavor switch is already baked into `rows`
  // and `baseIdx` above — emu pre-24, jit 24+. Per-platform
  // baselines (baseIdx) anchor at each platform's own earliest
  // OTP, so the combined-line ratios show cumulative speedup
  // since each platform's first measured release.
  const allByBucketByMc = {};
  const xLabelByBucket = {};
  rows.forEach(r => {
    const otp = runOtp[r.label];
    if (!otp || !r.median_ms) return;
    const b = bucketFor(otp);
    if (otp !== canonByMcBucket[r.machine_class][b]) return;
    const bk = r.lang + "|" + r.machine_class + "|" + r.benchmark;
    const base = baseIdx[bk];
    if (!base || !base.ms) return;
    const ratio = base.ms / r.median_ms;
    if (!allByBucketByMc[b]) allByBucketByMc[b] = {};
    if (!allByBucketByMc[b][r.machine_class]) allByBucketByMc[b][r.machine_class] = [];
    allByBucketByMc[b][r.machine_class].push(ratio);
    if (!xLabelByBucket[b] || compareOtpVersions(otp, xLabelByBucket[b]) > 0) {
      xLabelByBucket[b] = otp;
    }
  });

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

  const allSeries = {
    label: "all platforms",
    data: Object.entries(allByBucketByMc)
      .map(([b, byMc]) => {
        const mcGeomeans = Object.entries(byMc).map(([mc, ratios]) => ({
          mc,
          y: geomean(ratios),
          n: ratios.length
        })).filter(e => e.y !== null);
        if (mcGeomeans.length === 0) return null;
        return {
          x: xLabelByBucket[b],
          y: geomean(mcGeomeans.map(e => e.y)),
          n_benchmarks: mcGeomeans.reduce((a, e) => a + e.n, 0),
          n_platforms: mcGeomeans.length,
          platforms: mcGeomeans.map(e => e.mc).sort()
        };
      })
      .filter(d => d !== null)
      .sort((a, b) => compareOtpVersions(a.x, b.x)),
    // Visually distinct: bold black line so the combined trend
    // doesn't blend with the per-platform palette.
    borderColor: "#111",
    backgroundColor: "#111",
    borderWidth: 3
  };
  const hasAllSeries = allSeries.data && allSeries.data.length > 0;

  return hasAllSeries ? [allSeries, ...archSeries] : archSeries;
}

let chart = null;
let snapshotChart = null;

/* BeamAsm JIT debuts (verified against each meta.json's
   runtime.emu_flavor): x86_64 (linux/windows) at OTP-24, linux-arm64
   at OTP-25, macos-arm64 (Apple Silicon) at OTP-26 — earlier OTP-25
   on macos-arm64 ships emu only because upstream disables the JIT
   there to dodge a Sonoma+ crash that no backport could fix.
   Verified locally: --enable-jit=yes on OTP-25.3.2.21 macos-arm64
   still SIGBUSes on macOS 26, so the upstream guard is correct.

   These cutoffs drive per-line segment styling in renderChart —
   dashed where a platform's data is emulator, solid where it's JIT.
   The "all platforms" aggregate stays fully solid: any per-platform
   detail about emu/jit is already conveyed by the per-platform
   lines, and dashing the aggregate as well would just clutter the
   heading line at the top of the chart. */
const JIT_CUTOFF_BY_PLATFORM = {
  "linux-x86_64":   24,
  "windows-x86_64": 24,
  "linux-arm64":    25,
  "macos-arm64":    26
};
function jitCutoffForSeriesLabel(label) {
  return JIT_CUTOFF_BY_PLATFORM[label] || null;
}

/* erlang.org-friendly palette: brand red on top, then the standard
   categorical wheel. Order matters — the first dataset (almost
   always erlang) gets the red. */
const PALETTE = [
  "#a2003e", "#0d6efd", "#1f6f33", "#e07b00", "#7b3eb3",
  "#6c757d", "#a05a2c", "#0a8f8f", "#bcbd22"
];

function colorFor(i) { return PALETTE[i % PALETTE.length]; }

/* Diagonal-stripe pattern for "emu fallback" snapshot bars — same
   base color as a normal bar, with white slashes overlaid so the
   reader sees at a glance that this bar came from emulator data
   (because that platform/major has no JIT build) rather than from
   the JIT flavor the user picked. Cached by color string. */
const _stripeCache = {};
function stripePatternFor(color) {
  if (typeof document === "undefined") return color;
  if (_stripeCache[color]) return _stripeCache[color];
  const c = document.createElement("canvas");
  c.width = 8;
  c.height = 8;
  const ctx = c.getContext("2d");
  ctx.fillStyle = color;
  ctx.fillRect(0, 0, 8, 8);
  ctx.strokeStyle = "rgba(255,255,255,0.55)";
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  // Three diagonals: one centred, two offsets so the pattern wraps
  // seamlessly across tile boundaries.
  for (const off of [-8, 0, 8]) {
    ctx.moveTo(off, 8);
    ctx.lineTo(off + 8, 0);
  }
  ctx.stroke();
  const pat = ctx.createPattern(c, "repeat");
  _stripeCache[color] = pat;
  return pat;
}

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
  // X axis is OTP version for suite/per-bench pages; timestamp for
  // the master timeline (one point per merge, plotted at the
  // commit's committer date). The master page's dataset is already
  // collapsed server-side to one "aggregate" row per (run × series),
  // so buildSeries on the timestamp axis produces the trend lines
  // directly — no separate geomean builder needed.
  const xAxis = PAGE_KIND === "master" ? "timestamp" : "otp";
  const state = readUIState();
  const series = PAGE_KIND === "suite"
    ? buildSuiteGeomeanSeries()
    : buildSeries(applyFilters(DATASET.rows, state), xAxis, state.show_whiskers);

  const datasets = series.map((s, i) => {
    const baseColor = s.borderColor || colorFor(i);
    // Segments to the left of the platform's JIT-debut x render
    // dashed (emulator data) and segments at or right of it render
    // solid (real JIT data). `p0.parsed.x < cutoff` means "segment
    // STARTS in emu territory" — so the dashed→solid transition
    // happens AT the first JIT point, not one segment earlier.
    const cutoff = PAGE_KIND === "suite" ? jitCutoffForSeriesLabel(s.label) : null;
    return {
      label: s.label,
      data: s.data,
      borderColor: s.borderColor || baseColor,
      backgroundColor: s.backgroundColor || baseColor,
      borderWidth: s.borderWidth || 2,
      // Base style is solid; segment callback can override.
      borderDash: [],
      segment: cutoff != null
        ? { borderDash: (ctx) => ctx.p0.parsed.x < cutoff ? [5, 5] : [] }
        : undefined,
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

  // Inline Chart.js plugin for the master timeline page that paints
  // each tagged datapoint's otp_tag (e.g. "OTP-28.5") just above the
  // point. Skipping null tags (master merges) keeps the chart legible
  // — the user identifies merges by clicking the dot, not by reading
  // 13+ short-SHA labels overlapping on the right edge of the chart.
  const masterTagLabelsPlugin = {
    id: "masterTagLabels",
    afterDatasetsDraw: (chart) => {
      if (PAGE_KIND !== "master") return;
      const ctx = chart.ctx;
      ctx.save();
      ctx.font = "11px Montserrat, sans-serif";
      ctx.fillStyle = "#444";
      ctx.textAlign = "center";
      ctx.textBaseline = "bottom";
      chart.data.datasets.forEach((ds, di) => {
        const meta = chart.getDatasetMeta(di);
        ds.data.forEach((d, i) => {
          if (!d.otp_tag) return;
          const pt = meta.data[i];
          if (!pt) return;
          // Strip the "OTP-" prefix for chart legibility — the page
          // header already says these are OTP versions. Keep the
          // tag attribute itself untouched so the drill-down can
          // still report "OTP-28.5".
          const label = d.otp_tag.replace(/^OTP-/, "");
          ctx.fillText(label, pt.x, pt.y - 6);
        });
      });
      ctx.restore();
    }
  };

  if (chart) chart.destroy();
  chart = new Chart(document.getElementById("chart"), {
    type: chartType,
    data: { datasets },
    plugins: [masterTagLabelsPlugin],
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
              title: { display: true, text: "Erlang/OTP version", font: titleFont },
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
              if (xAxis === "otp") return "Erlang/OTP " + (r.otpLabel || r.x);
              return new Date(r.x).toLocaleString();
            },
            label: (ctx) => {
              const r = ctx.raw;
              const v = (typeof r.y === "number") ? r.y.toFixed(3) : r.y;
              let line = ctx.dataset.label + ": " + v + "×";
              if (typeof r.median_ms === "number") line += "  (" + r.median_ms.toFixed(2) + " ms)";
              if (r.stddev !== undefined && r.stddev !== null) line += "  σ=" + r.stddev.toFixed(2) + " ms";
              if (r.n_platforms) {
                line += "  (" + r.n_benchmarks + " ratios over " +
                  r.n_platforms + " platform" +
                  (r.n_platforms === 1 ? "" : "s") + ")";
              } else if (r.n_benchmarks) {
                line += "  (" + r.n_benchmarks + " ratios)";
              }
              return line;
            },
            afterBody: (items) => {
              if (!items.length) return "";
              const r = items[0].raw;
              return r.run_label ? "run: " + r.run_label : "";
            }
          }
        }
      },
      // Per-page click semantics:
      //  * master   — pin a drill-down card (commit subject + PR
      //               link + per-benchmark table) for the clicked
      //               datapoint.
      //  * bench    — pin a sparkline card for XMPP rows; no-op for
      //               synthetic rows.
      onClick: (evt, elements, chart) => {
        if (!elements.length) return;
        const el = elements[0];
        const raw = chart.data.datasets[el.datasetIndex].data[el.index];
        if (!raw) return;
        if (PAGE_KIND === "master") {
          pinMasterDrillCard({
            run_label: raw.run_label,
            series_label: chart.data.datasets[el.datasetIndex].label,
            otp_tag: raw.otp_tag,
            run_sha: raw.run_sha,
            bench_details: raw.bench_details,
            base_ms: raw.base_ms,
            ratio: raw.y,
            timestamp: raw.x
          });
          return;
        }
        if (!raw.samples) return;
        pinSparklineCard({
          run_label: raw.run_label,
          series_label: chart.data.datasets[el.datasetIndex].label,
          otp: raw.otp_for_panel,
          machine_class: raw.machine_class_for_panel,
          flavor: raw.flavor_for_panel,
          samples: raw.samples,
          samples_unit: raw.samples_unit,
          median_ms: raw.median_ms
        });
      }
    }
  });
}

/* ---- Per-bench sparkline comparison panel -------------------------
   Click any datapoint on a per-bench page to pin its per-second
   sample shape (CPU%, mem MB, msg/s for XMPP) to the panel below.
   Multiple clicks accumulate so master and 28.5 can be compared on
   the same screen. Same SVG layout as the stability page's
   drill-down, kept duplicated rather than refactored — the panel
   only renders on per-bench pages and stability has its own scope.
*/
function fmtSparkUnit(n, unit) {
  if (n === null || n === undefined || isNaN(n)) return "—";
  if (unit === "msg/s") return n.toFixed(0) + " " + unit;
  if (unit === "%") return n.toFixed(1) + " " + unit;
  if (unit === "MB") return n.toFixed(0) + " " + unit;
  return n.toFixed(2);
}
function sparklineSVG(samples, unit) {
  if (!samples || samples.length < 2) return "";
  const w = 360, h = 70, padL = 36, padR = 8, padT = 8, padB = 18;
  const innerW = w - padL - padR, innerH = h - padT - padB;
  const lo = Math.min(...samples);
  const hi = Math.max(...samples);
  const range = Math.max(hi - lo, 1e-12);
  const x = (i) => padL + (i / (samples.length - 1)) * innerW;
  const y = (v) => padT + (1 - (v - lo) / range) * innerH;
  let d = "M" + x(0) + "," + y(samples[0]);
  for (let i = 1; i < samples.length; i++) d += " L" + x(i) + "," + y(samples[i]);
  const mean = samples.reduce((a, b) => a + b, 0) / samples.length;
  const my = y(mean);
  const parts = [];
  parts.push('<text x="' + (padL - 4) + '" y="' + (padT + 4) + '" font-size="9" fill="#666" text-anchor="end">' + fmtSparkUnit(hi, unit) + '</text>');
  parts.push('<text x="' + (padL - 4) + '" y="' + (padT + innerH) + '" font-size="9" fill="#666" text-anchor="end">' + fmtSparkUnit(lo, unit) + '</text>');
  parts.push('<text x="' + padL + '" y="' + (h - 4) + '" font-size="9" fill="#666" text-anchor="start">0 s</text>');
  parts.push('<text x="' + (w - padR) + '" y="' + (h - 4) + '" font-size="9" fill="#666" text-anchor="end">' + (samples.length - 1) + ' s</text>');
  parts.push('<line x1="' + padL + '" y1="' + my + '" x2="' + (w - padR) + '" y2="' + my + '" stroke="#a2003e" stroke-dasharray="2,3" stroke-width="1" opacity="0.6"/>');
  parts.push('<text x="' + (w - padR) + '" y="' + (my - 2) + '" font-size="9" fill="#a2003e" text-anchor="end">mean ' + fmtSparkUnit(mean, unit) + '</text>');
  parts.push('<path d="' + d + '" fill="none" stroke="#a2003e" stroke-width="1.5"/>');
  return '<svg width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '" role="img" aria-label="per-second samples">' + parts.join("") + '</svg>';
}
// Avoid pinning the same (run_label × series) twice — clicking the
// same point should not stack duplicate cards. Identity uses the
// chart series label (machine_class / lang / flavor distinction)
// alongside run_label so the same OTP measured on two platforms can
// each have a pinned card.
const pinnedKeys = new Set();
// ---------- Master timeline drill-down -------------------------------
// Clicking a datapoint on master.html pins a card to #master-drill
// with: (1) the OTP identity (tag or short SHA), (2) the commit
// subject + PR link, lazy-fetched from api.github.com and cached in
// localStorage so a re-click is instant and a re-render keeps the
// data, (3) a per-benchmark median table from the embedded
// `bench_details` array.
const masterDrillKeys = new Set();

function pinMasterDrillCard(info) {
  const panel = document.getElementById("master-drill");
  if (!panel) return;
  const key = info.run_label + "::" + info.series_label;
  if (masterDrillKeys.has(key)) return;
  masterDrillKeys.add(key);

  // Header + clear-all button on first card pin.
  if (!document.getElementById("master-drill-head")) {
    const head = document.createElement("div");
    head.id = "master-drill-head";
    head.className = "master-drill-head";
    head.innerHTML =
      '<h3>Click a point for details</h3>' +
      '<p class="sub">Each click pins a card with the commit, PR, and per-benchmark medians for that datapoint. Click again to drop a pinned card.</p>' +
      '<button id="master-drill-clear" type="button" class="reset-btn">Clear all</button>';
    panel.appendChild(head);
    document.getElementById("master-drill-clear").addEventListener("click", () => {
      masterDrillKeys.clear();
      masterDrillDatasets.clear();
      rebuildSharedDrillChart();
      panel.innerHTML = "";
    });
  }

  const sha10 = (info.run_sha || "").slice(0, 10);
  const title = info.otp_tag || (sha10 ? "master@" + sha10 : "master");
  const dateStr = info.timestamp ? new Date(info.timestamp).toLocaleString() : "";

  // Each pinned card gets a stable color from a palette; that color
  // also tints the card's bar dataset in the shared chart below so
  // the eye can pair card ↔ bars across the page.
  const cardColor = pickCardColor(masterDrillKeys.size);

  const card = document.createElement("div");
  card.className = "master-drill-card";
  card.dataset.key = key;
  card.style.borderLeft = "4px solid " + cardColor;
  card.innerHTML =
    '<div class="master-drill-card-head">' +
      '<span class="master-drill-card-title">' + escapeHtml(title) + '</span>' +
      '<span class="master-drill-card-sub">' + escapeHtml(info.series_label) +
        (dateStr ? ' · ' + escapeHtml(dateStr) : '') + '</span>' +
      '<button class="master-drill-card-x" type="button" title="Remove">×</button>' +
    '</div>' +
    '<div class="master-drill-card-ratio">' +
      (typeof info.ratio === "number" ? info.ratio.toFixed(3) + '× vs anchor' : '') +
    '</div>' +
    '<div class="master-drill-card-pr"><em style="color: var(--er-muted)">Loading PR info…</em></div>' +
    '<details class="master-drill-card-benches">' +
      '<summary>Per-benchmark table (' + (info.bench_details ? info.bench_details.length : 0) + ')</summary>' +
      renderBenchDetailsTable(info.bench_details) +
    '</details>';

  card.querySelector(".master-drill-card-x").addEventListener("click", () => {
    masterDrillKeys.delete(key);
    masterDrillDatasets.delete(key);
    card.remove();
    rebuildSharedDrillChart();
    if (!panel.querySelector(".master-drill-card")) panel.innerHTML = "";
  });
  panel.appendChild(card);

  // Register this point's per-benchmark data in the shared chart.
  // The chart lives outside the card so multiple pinned points are
  // comparable in one place — see #master-drill-chart-wrap in the
  // page template. Horizontal bars (indexAxis: "y") because there
  // are 25+ benchmarks per point and vertical bars would clip the
  // names on a narrow viewport.
  masterDrillDatasets.set(key, {
    title: title,
    color: cardColor,
    bench_details: info.bench_details || []
  });
  rebuildSharedDrillChart();

  // Lazy-load PR info from api.github.com. CORS-enabled, public-readable,
  // no auth needed for the 60 req/hr free-tier limit (one click = one
  // request, dashboard caches per SHA in localStorage). Master-merge
  // commits typically have one PR; maint-tip release commits typically
  // have none.
  if (info.run_sha) {
    fetchCommitInfo(info.run_sha).then((data) => {
      const el = card.querySelector(".master-drill-card-pr");
      if (el && data) el.innerHTML = renderPrInfo(data);
    }).catch(() => {
      const el = card.querySelector(".master-drill-card-pr");
      if (el) el.innerHTML = '<em style="color: var(--er-muted)">PR lookup failed (rate-limited or offline).</em>';
    });
  } else {
    const el = card.querySelector(".master-drill-card-pr");
    if (el) el.innerHTML = '<em style="color: var(--er-muted)">No commit SHA recorded for this run.</em>';
  }
}

// Shared bar chart for the master-timeline drill-down. Lives outside
// the cards (above the card grid) so multiple pinned points show up
// as grouped bars side-by-side per benchmark — a single glance
// answers "which benchmark moved when going from this commit to that
// commit". Horizontal bars (indexAxis: "y") because there are 25+
// benchmark names per point and vertical labels would clip on
// narrow viewports.
const masterDrillDatasets = new Map(); // key -> { title, color, bench_details }
const DRILL_CARD_COLORS = [
  "#a2003e", // AWFY red
  "#5a78b8", // soft blue
  "#3d8b41", // green
  "#b58900", // amber
  "#8d4198", // purple
  "#0a8294"  // teal
];
function pickCardColor(idx) {
  return DRILL_CARD_COLORS[idx % DRILL_CARD_COLORS.length];
}

let sharedDrillChart = null;

function rebuildSharedDrillChart() {
  const wrap = document.getElementById("master-drill-chart-wrap");
  const canvas = document.getElementById("master-drill-shared-chart");
  if (!wrap || !canvas) return;

  if (masterDrillDatasets.size === 0) {
    if (sharedDrillChart) { sharedDrillChart.destroy(); sharedDrillChart = null; }
    wrap.style.display = "none";
    return;
  }

  // Build the union of benchmark names across pinned points so the
  // y-axis covers everything any card carries. Stable order: group
  // by language family, then alphabetical within family. Matches
  // what the per-card chart used to do.
  const labelMap = new Map(); // bench-key -> { name, lang, input }
  masterDrillDatasets.forEach(({ bench_details }) => {
    bench_details.forEach(d => {
      const key = (d.lang || "") + "|" + d.name + "|" + (d.input || "");
      if (!labelMap.has(key)) labelMap.set(key, d);
    });
  });
  const labels = Array.from(labelMap.values()).sort((a, b) => {
    const fam = (d) => d.lang === "erlang" ? 0 : d.lang === "elixir" ? 1 : 2;
    const fa = fam(a), fb = fam(b);
    if (fa !== fb) return fa - fb;
    return (a.name + (a.input || "")).localeCompare(b.name + (b.input || ""));
  });
  const labelKey = (d) => (d.lang || "") + "|" + d.name + "|" + (d.input || "");
  const labelDisplayNames = labels.map(d =>
    (d.input ? d.name + "/" + d.input : d.name) + (d.lang ? " · " + d.lang : "")
  );

  // One dataset per pinned card. Each dataset has one bar per
  // benchmark; null where the card's point didn't have that bench.
  const datasets = Array.from(masterDrillDatasets.entries()).map(([_key, info]) => {
    const byKey = new Map();
    info.bench_details.forEach(d => byKey.set(labelKey(d), d));
    const data = labels.map(d => {
      const found = byKey.get(labelKey(d));
      return found && typeof found.speedup === "number" ? found.speedup : null;
    });
    return {
      label: info.title,
      data,
      backgroundColor: info.color,
      borderWidth: 0
    };
  });

  // Chart height scales with the number of benchmarks so each bar
  // is readable. ~22 px per benchmark row gives the labels
  // breathing room.
  wrap.style.display = "";
  wrap.style.height = Math.max(220, labels.length * 22) + "px";

  if (sharedDrillChart) sharedDrillChart.destroy();
  sharedDrillChart = new Chart(canvas, {
    type: "bar",
    data: { labels: labelDisplayNames, datasets },
    options: {
      indexAxis: "y",
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      plugins: {
        legend: { position: "top", labels: { boxWidth: 14, font: { size: 11 } } },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              const v = ctx.raw;
              return ctx.dataset.label + ": " +
                (typeof v === "number" ? v.toFixed(3) + "×" : "—");
            }
          }
        }
      },
      scales: {
        x: {
          title: { display: true, text: "× speedup vs baseline", font: { size: 11 } },
          ticks: { font: { size: 10 } },
          beginAtZero: true
        },
        y: {
          ticks: { font: { size: 10 }, autoSkip: false },
          grid: { display: false }
        }
      }
    }
  });
}

function renderBenchDetailsTable(details) {
  if (!details || !details.length) {
    return '<p class="sub">No per-benchmark detail available.</p>';
  }
  const rows = details.map(d => {
    const name = d.input ? d.name + "/" + d.input : d.name;
    const langSuffix = d.lang ? " · " + d.lang : "";
    const median = (typeof d.median_ms === "number") ? d.median_ms.toFixed(3) + " ms" : "—";
    // Speedup column: baseline_ms / median_ms from the server-side
    // per-(series, benchmark) baseline. > 1 = faster than baseline,
    // < 1 = slower. Blank means no baseline for this benchmark in
    // this series (e.g. XMPP rows on a pre-27 series — there's no
    // earlier point to ratio against).
    const speedup = (typeof d.speedup === "number") ? d.speedup.toFixed(3) + "×" : "—";
    return '<tr><td>' + escapeHtml(name + langSuffix) + '</td><td class="num">' + median + '</td><td class="num">' + speedup + '</td></tr>';
  }).join("");
  return '<table class="master-drill-benches"><thead><tr><th>benchmark</th><th class="num">median</th><th class="num">speedup</th></tr></thead><tbody>' + rows + '</tbody></table>';
}

// Look up an erlang/otp commit + its associated PRs. Caches per SHA in
// localStorage; first click hits the network, subsequent clicks (and
// page reloads) are instant.
//
// erlang/otp accepts PRs targeting either `master` OR `maint`:
//   * master-targeted PRs land on master directly — the
//     `/commits/<sha>/pulls` call returns the PR straight away.
//   * maint-targeted PRs land on maint first, then maint forward-
//     merges into master via "Merge branch 'maint'" commits that
//     have no direct PR association — the maint-side parent
//     (parent[1]) carries the PR. We fall through to that when the
//     direct lookup returns empty AND the commit looks like a merge.
//
// Multi-PR maint→master merges (several feature commits in one
// range) aren't fully resolved here — the maint-side parent's
// pulls only covers the most-recent PR. The GitHub-diff link from
// the commit subject lets the user navigate from there for the
// fancier cases.
async function fetchCommitInfo(sha) {
  // v2 key: schema bumped when we started populating run_sha with
  // the OTP commit SHA (extracted from the run label) instead of
  // the AWFY repo's git SHA. Old v1 entries are stale and would
  // mislead the drill-down.
  const cacheKey = "awfy.master.commit.v2." + sha;
  const cached = localStorage.getItem(cacheKey);
  if (cached) {
    try { return JSON.parse(cached); } catch (_) {}
  }
  const [commit, directPulls] = await Promise.all([
    fetch("https://api.github.com/repos/erlang/otp/commits/" + sha)
      .then(r => r.ok ? r.json() : null),
    fetch("https://api.github.com/repos/erlang/otp/commits/" + sha + "/pulls")
      .then(r => r.ok ? r.json() : [])
  ]);

  let pulls = Array.isArray(directPulls) ? directPulls : [];

  if (pulls.length === 0 && commit && Array.isArray(commit.parents) && commit.parents.length === 2) {
    const subject = (commit.commit && commit.commit.message || "").split("\n")[0];
    if (/^Merge (branch|pull request)/.test(subject)) {
      const maintSide = commit.parents[1].sha;
      const maintPulls = await fetch(
        "https://api.github.com/repos/erlang/otp/commits/" + maintSide + "/pulls"
      ).then(r => r.ok ? r.json() : []);
      if (Array.isArray(maintPulls) && maintPulls.length) {
        pulls = maintPulls;
      }
    }
  }

  const info = { commit, pulls };
  try { localStorage.setItem(cacheKey, JSON.stringify(info)); } catch (_) {}
  return info;
}

function renderPrInfo(info) {
  if (!info || (!info.commit && (!info.pulls || !info.pulls.length))) {
    // 404 / private repo / rate-limit. Empty output would leave the
    // "Loading…" placeholder gone with nothing in its place, which
    // reads as "the drill-down is broken". Be explicit instead.
    return '<em style="color: var(--er-muted)">Commit not found on erlang/otp (rate-limited, offline, or stale local cache).</em>';
  }
  const parts = [];
  if (info.commit) {
    const c = info.commit;
    const subject = (c.commit && c.commit.message || "").split("\n")[0];
    const author = c.commit && c.commit.author && c.commit.author.name;
    parts.push('<div class="master-drill-card-commit">' +
      '<a href="' + c.html_url + '" target="_blank" rel="noopener">' + c.sha.slice(0, 10) + '</a>: ' +
      escapeHtml(subject) +
      (author ? ' <span style="color: var(--er-muted)">— ' + escapeHtml(author) + '</span>' : '') +
      '</div>');
  }
  if (info.pulls && info.pulls.length) {
    const links = info.pulls.map(p =>
      '<a href="' + p.html_url + '" target="_blank" rel="noopener">#' + p.number + '</a> ' + escapeHtml(p.title)
    ).join("<br>");
    parts.push('<div class="master-drill-card-pulls"><b>PR' + (info.pulls.length > 1 ? 's' : '') + ':</b> ' + links + '</div>');
  } else if (info.commit) {
    // erlang/otp typically merges feature branches into `maint`
    // first, then periodically merges `maint` into `master` via
    // "Merge branch 'maint'" commits — so master-merge SHAs often
    // have no direct PR association. The commit subject + GitHub
    // link above lets the user navigate from there to find the
    // underlying changes.
    parts.push('<div class="master-drill-card-pulls"><em style="color: var(--er-muted)">No PR directly associated with this commit. Click the SHA above to see the GitHub diff.</em></div>');
  }
  return parts.join("");
}

function pinSparklineCard(info) {
  const panel = document.getElementById("spark-panel");
  if (!panel) return;
  const key = info.run_label + "::" + info.series_label;
  if (pinnedKeys.has(key)) return;
  pinnedKeys.add(key);

  // Ensure the panel header/clear button exists once the first card pins.
  if (!document.getElementById("spark-panel-head")) {
    const head = document.createElement("div");
    head.id = "spark-panel-head";
    head.className = "spark-panel-head";
    head.innerHTML =
      '<h3>Per-run sample comparison</h3>' +
      '<p class="sub">Per-second values across the measurement window for each clicked run. ' +
      'Click another datapoint to pin it for side-by-side comparison.</p>' +
      '<button id="spark-panel-clear" type="button" class="reset-btn">Clear all</button>';
    panel.appendChild(head);
    document.getElementById("spark-panel-clear").addEventListener("click", () => {
      pinnedKeys.clear();
      panel.innerHTML = "";
    });
  }

  const samples = info.samples;
  const sum = samples.reduce((a, b) => a + b, 0);
  const mean = sum / samples.length;
  const sorted = samples.slice().sort((a, b) => a - b);
  const sMin = sorted[0], sMax = sorted[sorted.length - 1];
  const sMed = sorted[Math.floor(sorted.length / 2)];

  const card = document.createElement("div");
  card.className = "spark-card";
  card.innerHTML =
    '<div class="spark-card-head">' +
      '<span class="spark-card-title">OTP ' + (info.otp || "?") + ' · ' + info.series_label +
        (info.flavor ? ' · ' + info.flavor : '') + '</span>' +
      '<button class="spark-card-x" type="button" title="Remove">×</button>' +
    '</div>' +
    '<div class="spark-card-sub">' + (info.run_label || "") + '</div>' +
    sparklineSVG(samples, info.samples_unit) +
    '<dl class="spark-card-stats">' +
      '<dt>samples</dt><dd>' + samples.length + '</dd>' +
      '<dt>min</dt><dd>' + fmtSparkUnit(sMin, info.samples_unit) + '</dd>' +
      '<dt>median</dt><dd>' + fmtSparkUnit(sMed, info.samples_unit) + '</dd>' +
      '<dt>mean</dt><dd>' + fmtSparkUnit(mean, info.samples_unit) + '</dd>' +
      '<dt>max</dt><dd>' + fmtSparkUnit(sMax, info.samples_unit) + '</dd>' +
    '</dl>';
  card.querySelector(".spark-card-x").addEventListener("click", () => {
    pinnedKeys.delete(key);
    card.remove();
    // If all cards removed, also remove the header for a clean state.
    if (!panel.querySelector(".spark-card")) panel.innerHTML = "";
  });
  panel.appendChild(card);
}

/* ---- Headline metric ----------------------------------------------
   "OTP X is N× faster than OTP Y and M× faster than OTP Z."
   Uses the same data as the trend chart's "all platforms" line —
   geomean-of-per-platform-geomeans, pre-24 emu / post-24 jit, all
   benchmarks across all platforms. Independent of UI filters so the
   long-term anchor (typically OTP-20.3) is always visible.
*/
function renderHeadline() {
  const el = document.getElementById("headline");
  if (!el) return;
  const series = buildSuiteGeomeanSeries();
  const allSeries = series.find(s => s.label === "all platforms");
  if (!allSeries || allSeries.data.length < 2) {
    el.innerHTML = '<span class="empty">Need at least two OTP versions for a comparison.</span>';
    return;
  }

  // Released-only anchors (drop master/maint — they're rolling refs).
  const points = allSeries.data.filter(p => /^[0-9]/.test(p.x));
  if (points.length < 2) {
    el.innerHTML = '<span class="empty">Need at least two OTP versions for a comparison.</span>';
    return;
  }
  const newest = points[points.length - 1];
  const newestMajor = parseInt(newest.x, 10);
  const oldest = points[0];
  // Mid-anchor: newest_major - 2 (oldest supported release). Pick the
  // newest point inside that major so we land on the patch tip the
  // trend chart actually plotted.
  const midMajor = newestMajor - 2;
  const midCandidates = points.filter(p => parseInt(p.x, 10) === midMajor);
  const mid = midCandidates.length > 0 ? midCandidates[midCandidates.length - 1] : null;

  const anchorList = [];
  if (mid && mid.x !== newest.x) anchorList.push(mid);
  if (oldest.x !== newest.x && (!mid || oldest.x !== mid.x)) anchorList.push(oldest);
  if (anchorList.length === 0) {
    el.innerHTML = '<span class="empty">Need at least two OTP versions for a comparison.</span>';
    return;
  }

  // Speedup of newest vs anchor = newest.y / anchor.y. Both y-values
  // are speedup over the per-platform earliest baseline; the baseline
  // cancels in the ratio so we get the true newest:anchor multiplier.
  const fmtAnchor = (anchor) => {
    const speedup = newest.y / anchor.y;
    const pct = (speedup - 1) * 100;
    const word = pct >= 0 ? "faster" : "slower";
    const cls = pct >= 0 ? "speedup" : "slowdown";
    return '<span class="num ' + cls + '">' + speedup.toFixed(2) + '×</span> ' +
           '<span class="' + cls + '">' + word + '</span> than ' + anchor.x;
  };

  const parts = anchorList.map(fmtAnchor);
  const joined = parts.length === 1 ? parts[0] : parts.join(' and ');
  el.innerHTML = '<div>Erlang/OTP ' + newest.x + ' is ' + joined +
                 ' &nbsp; <span style="color: var(--er-muted); font-size: 0.9em;">geomean across all platforms</span></div>';
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

  // BeamAsm JIT debuts per platform — same cutoffs the trend chart
  // applies. When the user picks `jit` flavor, OTP majors below
  // their platform's cutoff have no JIT build and we fall back to
  // emu rows so the bars don't disappear. Tagged `emu_fallback`
  // downstream so the bar is rendered visually distinct from a
  // "real" JIT bar at the same major.
  const platformCutoff = JIT_CUTOFF_BY_PLATFORM[state.machine_class] || 0;
  const flavorForMajor = (m) => {
    if (state.emu_flavor === "emu") return "emu";
    const mn = parseInt(m, 10);
    return Number.isFinite(mn) && mn < platformCutoff ? "emu" : state.emu_flavor;
  };
  const passesFlavor = (r) =>
    r.emu_flavor === flavorForMajor(majorOf(r.otp));
  const isFallback = (r) =>
    state.emu_flavor === "jit" && r.emu_flavor === "emu";

  const langOK = Array.isArray(state.lang)
    ? (r) => state.lang.includes(seriesAxis(r))
    : (r) => seriesAxis(r) === state.lang;
  const mcOK = (r) => r.machine_class === state.machine_class;

  // estone is multi-input (rows have lang=null, input=<scenario>) so
  // the snapshot's lang-based filter would skip it. Fold its 8 per-
  // input medians into one synthetic Erlang row per (label) using
  // geomean — the bar then sits alongside the AWFY single-cell ones.
  // Note: 8 inputs is the current shape of apps/otp_benchmarks's
  // estone module, which covers ~6 of the 20 micros in upstream's
  // erts/emulator/test/estone_SUITE.erl; the canonical weighted
  // ESTONES headline also isn't reproduced. Folding what's there
  // is the right thing for the snapshot now; expanding the suite is
  // a separate workstream.
  const allRows = DATASET.rows.slice();
  const estoneByLabel = {};
  DATASET.rows.forEach(r => {
    if (r.benchmark !== "estone" || !r.input) return;
    if (typeof r.median_ms !== "number" || r.median_ms <= 0) return;
    if (!estoneByLabel[r.label]) estoneByLabel[r.label] = { template: r, medians: [] };
    estoneByLabel[r.label].medians.push(r.median_ms);
  });
  Object.values(estoneByLabel).forEach(({ template, medians }) => {
    if (medians.length === 0) return;
    const sumLog = medians.reduce((a, m) => a + Math.log(m), 0);
    const geomeanMs = Math.exp(sumLog / medians.length);
    allRows.push({
      ...template,
      input: null,
      lang: "erlang",
      median_ms: geomeanMs,
      // stddev across input geomeans isn't comparable to the single-
      // sample stddev fields the snapshot whisker reads. Null it out
      // so the bar renders without whiskers — accurate is better
      // than a misleading whisker on a synthetic point.
      stddev_ms: null
    });
  });

  const filtered = allRows.filter(r =>
    langOK(r) && mcOK(r) && passesFlavor(r) && enabledMajors.has(majorOf(r.otp))
  );

  // Baseline index built from the unfiltered row set so toggling
  // the major checkboxes can never accidentally shift the baseline
  // — it's always the dataset's earliest recorded run for each
  // (lang, machine_class, benchmark). Uses the same emu-pre-cutoff
  // fallback as the bars so the ratio stays apples-to-apples.
  // Uses allRows (= DATASET.rows + synthetic estone) so the estone
  // bar gets a real per-platform baseline at its earliest OTP.
  const baseIdx = {};
  allRows.forEach(r => {
    if (r.machine_class !== state.machine_class) return;
    if (!passesFlavor(r)) return;
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
        // Same 2σ-with-cap whisker as the line chart — visible
        // even at high N (we tried SE = σ/√N and the whiskers
        // collapsed sub-pixel on well-replicated benchmarks).
        // Cap at median/2 keeps the upper bound bounded at 2×
        // the ratio so a single high-CV bar can't push yMax
        // toward Infinity.
        const rawHalf = (typeof r.stddev_ms === "number") ? 2 * r.stddev_ms : 0;
        const half = rawHalf > r.median_ms / 2 ? r.median_ms / 2 : rawHalf;
        const yMax = (r.median_ms - half > 0) ? base.ms / (r.median_ms - half) : ratio;
        const yMin = (r.median_ms + half > 0) ? base.ms / (r.median_ms + half) : ratio;
        return {
          x: b,
          y: ratio,
          yMin: state.show_whiskers ? yMin : null,
          yMax: state.show_whiskers ? yMax : null,
          raw: r,
          baseMs: base.ms
        };
      });
      const v = versionForMajor[m];
      const labelOtp = (v === "master" || v === "main") ? v : "Erlang/OTP " + v;
      // If any of this (major, lang)'s rows is an emu fallback,
      // mark the whole dataset — within a major+lang every bench
      // shares the same flavor decision (driven by the major).
      const fallback = benches.some(b => {
        const r = latest[m + "|" + lang + "|" + b];
        return r && isFallback(r);
      });
      const color = colorFor(mi * langs.length + li);
      const suffix = fallback ? " (emu)" : "";
      // Elixir scenarios run under a per-OTP-major Elixir version
      // (24→1.16.3, 25→1.17.3, … see bin/elixir-for-otp.sh) — show
      // it in the legend so the reader can tell that an OTP-25 bar
      // for elixir is really "Elixir 1.17.3 on OTP-25". Erlang
      // scenarios don't depend on the Elixir version, so skip.
      // Erlang bars label as just "OTP X" — the erlang suffix is
      // surplus on every chart whose default Y axis is "Erlang/OTP
      // speedup". Elixir bars keep the suffix with the specific
      // Elixir version since that does change across OTP majors.
      let langTail = "";
      if (lang === "elixir") {
        const sampleRow = benches
          .map(b => latest[m + "|" + lang + "|" + b])
          .find(r => r && r.elixir);
        if (sampleRow) {
          // meta.json's elixir field is the host orchestrator's
          // version (always recent). On the legacy bundle path
          // (OTP < 24) the benchmarks run under a different,
          // OTP-major-specific Elixir compiled into the target
          // bundle. TARGET_ELIXIR_BY_MAJOR is injected at render
          // time via priv/elixir-for-otp.sh (shared with bench.yml
          // and the install scripts).
          const override = TARGET_ELIXIR_BY_MAJOR && TARGET_ELIXIR_BY_MAJOR[m];
          const majorN = parseInt(m, 10);
          const useOverride = override && Number.isFinite(majorN) && majorN < 24;
          langTail = " · Elixir " + (useOverride ? override : sampleRow.elixir);
        } else {
          langTail = " · Elixir";
        }
      }
      datasets.push({
        label: labelOtp + langTail + suffix,
        data,
        backgroundColor: fallback ? stripePatternFor(color) : color,
        borderColor: color,
        borderWidth: fallback ? 1.5 : 1,
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
          title: { display: true, text: "speedup × over baseline", font: titleFont },
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

/* ---- Machine specs card ------------------------------------------
   Surface what hardware + build the active machine_class was measured
   on. Picks the most-recent run for that machine_class so the card
   reflects the same build the trend / snapshot charts are drawing
   from. Fields not present on older runs (compiler, build flags) are
   simply skipped — the card stays useful with whatever's there.
*/
function renderMachineSpecs() {
  const el = document.getElementById("machine-specs");
  if (!el) return;
  const state = readUIState();
  const target = Array.isArray(state.machine_class) ? null : state.machine_class;
  if (!target) { el.innerHTML = ""; return; }

  const runs = DATASET.runs.filter(r => r.machine_class === target);
  if (runs.length === 0) { el.innerHTML = ""; return; }
  // Newest run first — assumes ISO-8601 timestamps sort lexically.
  runs.sort((a, b) => (b.timestamp || "").localeCompare(a.timestamp || ""));
  const r = runs[0];

  const row = (label, value) =>
    value == null || value === "" ? "" :
      "<dt>" + label + "</dt><dd>" + escapeHtml(String(value)) + "</dd>";

  const flags = r.build_flags
    ? '<dt>build flags</dt><dd class="build-flags">' + escapeHtml(r.build_flags) + "</dd>"
    : "";

  // Preserve the open/closed state across platform-tab switches —
  // once a user opens the specs they probably want to compare them
  // across tabs without re-clicking on every switch. The open flag
  // also persists in localStorage so a full page reload keeps the
  // user's last preference.
  const wasOpen = el.querySelector("details")?.hasAttribute("open")
    || (state.machine_specs_open === true);
  const openAttr = wasOpen ? " open" : "";

  el.innerHTML =
    "<details" + openAttr + ">" +
      "<summary>Show platform specs</summary>" +
      "<dl>" +
        row("cpu", r.cpu) +
        row("os", r.os) +
        row("arch", r.arch) +
        row("cores", r.cores) +
        row("compiler", r.c_compiler_used) +
        flags +
      "</dl>" +
    "</details>";

  // Persist toggle changes so the open state survives reload.
  const detailsEl = el.querySelector("details");
  if (detailsEl) {
    detailsEl.addEventListener("toggle", () => {
      const s = loadFilterState();
      s.machine_specs_open = detailsEl.open;
      saveFilterState(s);
    });
  }
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
}

function renderAll() {
  renderHeadline();
  renderChart();
  renderMachineSpecs();
  if (PAGE_KIND === "suite") renderSnapshot();
  if (PAGE_KIND === "bench") pinDefaultSparklineCard();
}

// Pin one default sparkline card on first load so users discover
// they can click datapoints to pin more. Prefers linux-x86_64 master
// (the dashboard's primary reference row), then any master row, then
// the latest available row with samples. No-op for synthetic
// benchmarks (no samples) and for runs with no master data yet.
function pinDefaultSparklineCard() {
  const candidates = DATASET.rows.filter(r =>
    r.samples && r.samples.length && r.benchmark === BENCH_NAME
  );
  if (!candidates.length) return;

  const prefer = (pred) =>
    candidates
      .filter(pred)
      .sort((a, b) => (a.timestamp < b.timestamp ? 1 : -1))[0];

  const pick =
    prefer(r => r.otp === "master" && r.machine_class === "linux-x86_64") ||
    prefer(r => r.otp === "master") ||
    prefer(() => true);

  if (!pick) return;

  pinSparklineCard({
    run_label: pick.label,
    series_label: pick.machine_class,
    otp: pick.otp,
    machine_class: pick.machine_class,
    flavor: pick.emu_flavor,
    samples: pick.samples,
    samples_unit: pick.samples_unit,
    median_ms: pick.median_ms
  });
}

function renderRunsMeta() {
  const lines = DATASET.runs.map(r =>
    r.timestamp + "  " + r.label.padEnd(40) +
    "  otp=" + r.otp + "  elixir=" + r.elixir +
    "  " + (r.machine_class || r.hostname || "?") + " (" + (r.cpu || "?") + ")  emu=" + (r.emu_flavor || "?")
  );
  document.getElementById("runs-meta").textContent = lines.join("\n");
}

/* Init */
// Guarded so the file can be required from Node (test runner) without
// crashing on `document.getElementById` — the helpers above are pure
// and re-exported via module.exports at the bottom of the file.
if (typeof document !== "undefined") (function () {
  // Master timeline page has no controls — server already collapsed
  // every row to one synthetic (mc, flavor) aggregate. Skip the
  // tab/radio/checkbox setup entirely; renderAll handles the chart.
  if (PAGE_KIND === "master") {
    renderAll();
    renderRunsMeta();
    return;
  }
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

  // Display→Error bars toggle. Default checked (whiskers on);
  // persisted false hides them. Same `onFilterChange` flow as the
  // other controls — readUIState picks up `.show_whiskers` and the
  // chart renderers honor it.
  const whiskerEl = document.getElementById("show-whiskers");
  if (whiskerEl) {
    if (state.show_whiskers === false) whiskerEl.checked = false;
    whiskerEl.addEventListener("change", onFilterChange);
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
