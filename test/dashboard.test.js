// SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
// SPDX-License-Identifier: Apache-2.0
//
// Vitest unit tests for the pure helpers in priv/dashboard.js.
//
// dashboard.js is a browser script (not an ES module) that's
// embedded inline into the generated HTML by awfy.compare.ex. It
// re-exports its pure helpers via `module.exports` at the bottom
// of the file, gated by `typeof module !== "undefined"` so the
// guard is a no-op in browsers. We can't `import` the file
// directly because it depends on browser globals like `document`
// and `localStorage` at top level — instead we read the source,
// stub the globals it touches, and run it in a vm sandbox so the
// init IIFE's typeof-document guard short-circuits.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import vm from "node:vm";
import { describe, it, expect, beforeAll } from "vitest";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_PATH = resolve(__dirname, "../priv/dashboard.js");

// Loaded once per test run; the helpers are pure so a single
// sandbox suffices for every test.
let dash;

beforeAll(() => {
  const src = readFileSync(SRC_PATH, "utf8");
  // Minimum globals the file references at top-level (STORAGE_KEY
  // concatenates PAGE_KIND and BENCH_NAME on load). The init IIFE
  // is guarded by `typeof document !== "undefined"`, so leaving
  // document undefined here means it's a no-op.
  const sandbox = {
    PAGE_KIND: "bench",
    BENCH_NAME: "TestBench",
    BASELINE_LABEL: "",
    DATASET: { rows: [], runs: [] },
    MAX_RELEASED_MAJOR: 28,
    module: { exports: {} },
    console
  };
  sandbox.exports = sandbox.module.exports;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: SRC_PATH });
  dash = sandbox.module.exports;
});

describe("compareOtpVersions", () => {
  it("orders dotted numeric versions", () => {
    expect(dash.compareOtpVersions("20.0", "20.1")).toBeLessThan(0);
    expect(dash.compareOtpVersions("21.0", "20.9")).toBeGreaterThan(0);
    expect(dash.compareOtpVersions("23.3.4.20", "23.3.4.20")).toBe(0);
    expect(dash.compareOtpVersions("23.3", "23.3.4.20")).toBeLessThan(0);
  });

  it("places master after every numeric version", () => {
    expect(dash.compareOtpVersions("master", "28.5")).toBeGreaterThan(0);
    expect(dash.compareOtpVersions("20.0", "master")).toBeLessThan(0);
    expect(dash.compareOtpVersions("master", "master")).toBe(0);
  });

  it("places maint between the highest numeric version and master", () => {
    // Regression test for the bug where parseInt("maint") = NaN
    // collapsed to 0, sorting maint before OTP-20 and producing a
    // back-edge from maint's render position to OTP-20 on the
    // geomean line.
    expect(dash.compareOtpVersions("maint", "28.5")).toBeGreaterThan(0);
    expect(dash.compareOtpVersions("20.0", "maint")).toBeLessThan(0);
    expect(dash.compareOtpVersions("maint", "master")).toBeLessThan(0);
    expect(dash.compareOtpVersions("master", "maint")).toBeGreaterThan(0);
  });

  it("sorts a mixed array correctly", () => {
    const arr = ["master", "21.0.9", "20.3", "maint", "28.5", "23.3.4.20"];
    arr.sort(dash.compareOtpVersions);
    expect(arr).toEqual(["20.3", "21.0.9", "23.3.4.20", "28.5", "maint", "master"]);
  });
});

describe("majorOf", () => {
  it("strips dotted versions to their major", () => {
    expect(dash.majorOf("23.3.4.20")).toBe("23");
    expect(dash.majorOf("28")).toBe("28");
    expect(dash.majorOf("28.5")).toBe("28");
  });

  it("passes floating refs through verbatim", () => {
    expect(dash.majorOf("master")).toBe("master");
    expect(dash.majorOf("main")).toBe("main");
    expect(dash.majorOf("maint-26")).toBe("maint-26");
  });

  it("returns null for unparseable input", () => {
    expect(dash.majorOf("not-a-version")).toBe(null);
    expect(dash.majorOf(null)).toBe(null);
  });
});

describe("seriesAxis", () => {
  it("returns lang for AWFY-shape rows", () => {
    expect(dash.seriesAxis({ lang: "erlang", input: null })).toBe("erlang");
  });

  it("returns input for OtpBenchmarks-shape rows (lang null)", () => {
    expect(dash.seriesAxis({ lang: null, input: "binary_4k" })).toBe("binary_4k");
  });

  it("prefers lang when both are populated (defensive)", () => {
    // Real rows never have both — the loader sets exactly one. But
    // if a future contract bug ever produces both, lang wins so
    // AWFY pages stay stable.
    expect(dash.seriesAxis({ lang: "erlang", input: "atom" })).toBe("erlang");
  });
});

describe("foldMultiInputFamilies", () => {
  it("passes AWFY rows through unchanged", () => {
    const awfyRows = [
      { lang: "erlang", input: null, median_ms: 100, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "Bounce", label: "v1", otp: "28.0", stddev_ms: 1 },
      { lang: "elixir", input: null, median_ms: 110, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "Bounce", label: "v1", otp: "28.0", stddev_ms: 2 }
    ];
    const out = dash.foldMultiInputFamilies(awfyRows);
    expect(out).toHaveLength(2);
    expect(out).toEqual(expect.arrayContaining(awfyRows));
  });

  it("folds OtpBenchmarks rows into one geomean cell per (label, mc, otp, family)", () => {
    const rows = [
      { lang: null, input: "atom", median_ms: 100, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0", stddev_ms: 1 },
      { lang: null, input: "binary_4k", median_ms: 400, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0", stddev_ms: 5 }
    ];
    const out = dash.foldMultiInputFamilies(rows);
    expect(out).toHaveLength(1);
    // Geomean of [100, 400] = sqrt(100*400) = 200.
    expect(out[0].median_ms).toBeCloseTo(200, 4);
    expect(out[0].input).toBeNull();
    // Family-level cell has no per-call sigma; whisker bars
    // would otherwise lie about confidence.
    expect(out[0].stddev_ms).toBe(0);
    // Other identifying fields preserved from the first row.
    expect(out[0].benchmark).toBe("phash2");
    expect(out[0].machine_class).toBe("macos-arm64");
    expect(out[0].label).toBe("v1");
    expect(out[0].otp).toBe("28.0");
  });

  it("keeps separate synthetic cells for different (label, mc) tuples", () => {
    const rows = [
      // Run v1 on macos-arm64.
      { lang: null, input: "a", median_ms: 100, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0" },
      { lang: null, input: "b", median_ms: 100, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0" },
      // Run v1 on linux-x86_64 (different mc → different synthetic cell).
      { lang: null, input: "a", median_ms: 200, machine_class: "linux-x86_64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0" }
    ];
    const out = dash.foldMultiInputFamilies(rows);
    expect(out).toHaveLength(2);
    const byMc = Object.fromEntries(out.map(r => [r.machine_class, r.median_ms]));
    expect(byMc["macos-arm64"]).toBeCloseTo(100, 4);
    expect(byMc["linux-x86_64"]).toBeCloseTo(200, 4);
  });

  it("drops a family from a (label, mc, otp) tuple when every input is missing/zero", () => {
    const rows = [
      { lang: null, input: "a", median_ms: null, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0" },
      { lang: null, input: "b", median_ms: 0, machine_class: "macos-arm64",
        emu_flavor: "jit", benchmark: "phash2", label: "v1", otp: "28.0" }
    ];
    const out = dash.foldMultiInputFamilies(rows);
    expect(out).toEqual([]);
  });
});

describe("seriesKey", () => {
  it("joins lang × machine_class × emu_flavor for AWFY rows", () => {
    expect(dash.seriesKey({
      lang: "erlang", input: null, machine_class: "linux-x86_64", emu_flavor: "jit"
    })).toBe("erlang / linux-x86_64 / jit");
  });

  it("uses input as the axis for OtpBenchmarks rows", () => {
    expect(dash.seriesKey({
      lang: null, input: "atom", machine_class: "linux-x86_64", emu_flavor: "jit"
    })).toBe("atom / linux-x86_64 / jit");
  });
});

describe("applyFilters", () => {
  const rows = [
    { lang: "erlang", machine_class: "linux-x86_64", emu_flavor: "jit" },
    { lang: "erlang", machine_class: "linux-arm64",  emu_flavor: "jit" },
    { lang: "erlang", machine_class: "macos-arm64",  emu_flavor: "jit" },
    { lang: "elixir", machine_class: "linux-x86_64", emu_flavor: "jit" },
    { lang: "erlang", machine_class: "linux-x86_64", emu_flavor: "emu" }
  ];

  it("filters with scalar lang and machine_class (suite shape)", () => {
    const out = dash.applyFilters(rows, {
      lang: "erlang", machine_class: "linux-x86_64", emu_flavor: "jit"
    });
    expect(out).toHaveLength(1);
    expect(out[0].machine_class).toBe("linux-x86_64");
  });

  it("filters with array machine_class (per-bench shape)", () => {
    const out = dash.applyFilters(rows, {
      lang: "erlang",
      machine_class: ["linux-x86_64", "linux-arm64"],
      emu_flavor: "jit"
    });
    expect(out).toHaveLength(2);
    expect(out.map(r => r.machine_class).sort()).toEqual(["linux-arm64", "linux-x86_64"]);
  });

  it("filters with array lang (legacy suite shape)", () => {
    const out = dash.applyFilters(rows, {
      lang: ["erlang", "elixir"],
      machine_class: "linux-x86_64",
      emu_flavor: "jit"
    });
    expect(out).toHaveLength(2);
    expect(out.map(r => r.lang).sort()).toEqual(["elixir", "erlang"]);
  });

  it("respects emu_flavor", () => {
    const out = dash.applyFilters(rows, {
      lang: "erlang", machine_class: "linux-x86_64", emu_flavor: "emu"
    });
    expect(out).toHaveLength(1);
    expect(out[0].emu_flavor).toBe("emu");
  });

  it("filters OtpBenchmarks rows by input via the lang control (multi-select)", () => {
    // The lang control on multi-input pages is a checkbox group;
    // state.lang is an array of checked input variants. applyFilters
    // already handles the array shape via includes(seriesAxis(r)).
    const otpRows = [
      { lang: null, input: "atom",      machine_class: "macos-arm64", emu_flavor: "jit" },
      { lang: null, input: "binary_4k", machine_class: "macos-arm64", emu_flavor: "jit" },
      { lang: null, input: "list_1000", machine_class: "macos-arm64", emu_flavor: "jit" }
    ];
    const out = dash.applyFilters(otpRows, {
      lang: ["atom", "binary_4k"], machine_class: "macos-arm64", emu_flavor: "jit"
    });
    expect(out).toHaveLength(2);
    expect(out.map(r => r.input).sort()).toEqual(["atom", "binary_4k"]);
  });
});

describe("buildOtpXMap", () => {
  it("places each numeric major at its integer slot", () => {
    const info = dash.buildOtpXMap(["20.0", "21.0", "22.0", "23.0"]);
    expect(info.numericMajors).toEqual([20, 21, 22, 23]);
    expect(info.maxNumeric).toBe(23);
    expect(info.map["20.0"]).toBe(20);
    expect(info.map["21.0"]).toBe(21);
  });

  it("subdivides points within a major as major+rank/count", () => {
    const info = dash.buildOtpXMap(["21.0", "21.1", "21.2", "21.3"]);
    expect(info.map["21.0"]).toBe(21);
    expect(info.map["21.1"]).toBeCloseTo(21.25, 5);
    expect(info.map["21.2"]).toBeCloseTo(21.5, 5);
    expect(info.map["21.3"]).toBeCloseTo(21.75, 5);
  });

  it("places master one slot past the highest major when no maint", () => {
    const info = dash.buildOtpXMap(["27.0", "28.0", "master"]);
    expect(info.hasMaster).toBe(true);
    expect(info.hasMaint).toBe(false);
    expect(info.maxNumeric).toBe(28);
    expect(info.masterX).toBe(29);
    expect(info.maintX).toBe(29); // unused but reported for symmetry
    expect(info.map.master).toBe(29);
  });

  it("places maint at +1 and master at +2 when both are present", () => {
    const info = dash.buildOtpXMap(["27.0", "28.0", "maint", "master"]);
    expect(info.hasMaster).toBe(true);
    expect(info.hasMaint).toBe(true);
    expect(info.maintX).toBe(29);
    expect(info.masterX).toBe(30);
    expect(info.map.maint).toBe(29);
    expect(info.map.master).toBe(30);
  });
});

describe("buildSeries", () => {
  // Synthetic dataset spanning two SHAs and two platforms, both
  // with stddev set so the whisker math has real bounds. Earliest
  // OTP per (lang, machine_class, benchmark) becomes the baseline.
  const rows = [
    { lang: "erlang", machine_class: "linux-x86_64", emu_flavor: "jit",
      benchmark: "NBody", otp: "27.0", median_ms: 1000, stddev_ms: 10,
      label: "27.0-test-linux-x86_64-jit", timestamp: "2026-01-01T00:00:00Z",
      inner_iter: 100 },
    { lang: "erlang", machine_class: "linux-x86_64", emu_flavor: "jit",
      benchmark: "NBody", otp: "28.0", median_ms: 800, stddev_ms: 8,
      label: "28.0-test-linux-x86_64-jit", timestamp: "2026-02-01T00:00:00Z",
      inner_iter: 100 },
    { lang: "erlang", machine_class: "linux-arm64",  emu_flavor: "jit",
      benchmark: "NBody", otp: "27.0", median_ms: 600, stddev_ms: 6,
      label: "27.0-test-linux-arm64-jit", timestamp: "2026-01-01T00:00:00Z",
      inner_iter: 100 },
    { lang: "erlang", machine_class: "linux-arm64",  emu_flavor: "jit",
      benchmark: "NBody", otp: "28.0", median_ms: 500, stddev_ms: 5,
      label: "28.0-test-linux-arm64-jit", timestamp: "2026-02-01T00:00:00Z",
      inner_iter: 100 }
  ];

  it("produces one series per (lang, machine_class, emu_flavor)", () => {
    const series = dash.buildSeries(rows, "otp");
    expect(series).toHaveLength(2);
  });

  it("anchors each series at its earliest OTP with ratio 1.0", () => {
    const series = dash.buildSeries(rows, "otp");
    for (const s of series) {
      // Sorted ascending by compareOtpVersions, so [0] is the
      // baseline at exactly 1×.
      expect(s.data[0].y).toBeCloseTo(1.0, 6);
    }
  });

  it("computes ratios as baseline_ms / current_ms (higher = faster)", () => {
    const series = dash.buildSeries(rows, "otp");
    const x86 = series.find(s => s.data.some(d => d.run_label.includes("x86_64")));
    // 1000 / 800 = 1.25× faster on OTP-28 vs OTP-27 for x86_64.
    expect(x86.data[1].y).toBeCloseTo(1.25, 4);
  });

  it("inverts the whisker: yMin uses ms+σ, yMax uses ms−σ", () => {
    const series = dash.buildSeries(rows, "otp");
    const x86 = series.find(s => s.data.some(d => d.run_label.includes("x86_64")));
    const p = x86.data[1]; // OTP-28: median 800, 2σ = 16
    // baseline / (ms - 2σ) = 1000 / 784  ≈ 1.2755
    // baseline / (ms + 2σ) = 1000 / 816  ≈ 1.2255
    expect(p.yMax).toBeCloseTo(1000 / 784, 4);
    expect(p.yMin).toBeCloseTo(1000 / 816, 4);
    expect(p.yMax).toBeGreaterThan(p.y);
    expect(p.yMin).toBeLessThan(p.y);
  });

  it("labels OtpBenchmarks series by input rather than machine_class", () => {
    // Multi-input rows have lang=null and input populated. The
    // chart should label each series by its input variant so the
    // legend reads "atom" / "binary_4k" / … rather than every
    // line saying "macos-arm64".
    const inputRows = [
      { lang: null, input: "atom", machine_class: "macos-arm64", emu_flavor: "jit",
        benchmark: "phash2", otp: "28.0", median_ms: 0.000013, stddev_ms: 0.00001,
        label: "test-otp", timestamp: "2026-05-01T00:00:00Z", inner_iter: null },
      { lang: null, input: "binary_4k", machine_class: "macos-arm64", emu_flavor: "jit",
        benchmark: "phash2", otp: "28.0", median_ms: 0.001584, stddev_ms: 0.00018,
        label: "test-otp", timestamp: "2026-05-01T00:00:00Z", inner_iter: null }
    ];
    const series = dash.buildSeries(inputRows, "otp");
    expect(series).toHaveLength(2);
    expect(series.map(s => s.label).sort()).toEqual(["atom", "binary_4k"]);
  });
});

describe("defaultMajorsSet", () => {
  it("includes the support window (current and previous two majors)", () => {
    // MAX_RELEASED_MAJOR is set to 28 in the sandbox.
    const out = dash.defaultMajorsSet(["20", "26", "27", "28", "29", "master"]);
    expect(out.has("28")).toBe(true);
    expect(out.has("27")).toBe(true);
    expect(out.has("26")).toBe(true);
    expect(out.has("20")).toBe(false);
    expect(out.has("29")).toBe(false); // upcoming, not yet released
  });

  it("always includes master", () => {
    const out = dash.defaultMajorsSet(["20", "master"]);
    expect(out.has("master")).toBe(true);
  });
});
