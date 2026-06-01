<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# AWFY Requirements

This document captures what AWFY is *supposed* to do — the
mission and the non-negotiable invariants. Each area's detailed
requirements live in a sibling file in this folder
(`REQUIREMENTS/<area>.md`). When the code drifts from what's here,
the doc wins: either fix the code, or update the requirement after
a deliberate decision.

## Mission

Give Erlang/OTP developers a single, public, reproducible view of
how OTP's runtime performance evolves across releases and master
merges, across the platforms and workloads that matter — so a
regression is caught before it ships and an improvement is visible
the day it lands.

## Invariants

These hold across every page, suite, platform, and OTP version. A
change that breaks one of these needs an explicit decision logged
against this file before it ships.

1. **Numbers on different pages agree.** The geomean speedup for
   `OTP-29.0` on the suite chart and on the master timeline must be
   the same number, computed from the same baseline (full-history
   anchor, typically `OTP-20.3`). Page-specific filters change
   *what's shown*, never *what the underlying number is*.

2. **History is immutable.** Adding a new SHA, benchmark, or
   platform must not change historical measurements. Each run-dir
   on `gh-pages` is content-addressed by `<sha10>` and is never
   rewritten — only added to or wiped wholesale by an `all`-mode
   dispatch.

3. **The fill process converges.** A platform's gap is either
   measurable (data lands) or marked unmeasurable (sentinel /
   `SKIP_PLATFORMS`) — no SHA may stay flagged as "needs work"
   across consecutive fills with the same upstream state, or the
   50-merge cap silently burns slots on phantom work.

4. **Measurement context is recorded.** Every run-dir carries
   enough `meta.json` context (OTP SHA, Elixir version, JIT/emu
   flavor, hostname class, build flags, commit timestamp) to
   reproduce the measurement and to render it correctly on the
   dashboard. A run-dir without meta is unusable and must not
   reach gh-pages.

5. **Pages render purely from gh-pages.** The dashboard is static
   HTML + JS reading the `.benchee` files committed to gh-pages —
   no runtime backend, no database. Anyone can serve the same
   bytes and get the same view.

6. **Cross-OTP support is honest.** A modern-path measurement
   (peer runner, same OTP as host) and a legacy-path measurement
   (target-bundle, cross-Elixir) of the same SHA at the same
   platform/flavor are presented as equivalent only when they're
   labelled as such; the dashboard surfaces the path used so a
   reader can judge.

7. **Noise is bounded and disclosed.** Measurement noise on any
   single (SHA, platform, benchmark) cell is small enough that the
   geomean speedup is comparable across runs (target: CV ≤ 5% on
   the publication-quality pool). Preflight gates power state,
   background load, and memory pressure; runs that don't clear
   preflight are visibly flagged.

8. **External flakes don't corrupt data.** Upstream registry
   outages, source-archive aging, compose-up timeouts, and similar
   external failures must result in either a successful re-run or
   a visible "unmeasurable" marker — they must never silently
   publish bogus numbers.

## Per-area requirements

Detailed behaviours under each of these surfaces live in their own
files; this index is the route in.

- [Dashboard](dashboard.md) — pages (suite chart, master timeline,
  per-benchmark), UX, filters, drill-downs.
- [Benchmarks](benchmarks.md) — AWFY synthetic, OtpBenchmarks
  (BEAM-internal), XMPP (MongooseIM + Amoc) suite contracts.
- [Measurement](measurement.md) — CI fill flow, resolver semantics,
  gap detection, local fills, label / run-dir conventions.
- [Platforms](platforms.md) — supported (OS, arch, OTP-major)
  matrix and per-cell behaviour, modern vs legacy paths,
  NO_INSTALLER sentinels, SKIP_PLATFORMS.
- [Infrastructure](infrastructure.md) — gh-pages layout, runner
  pools (GHA / AWS Terraform / local M5), scheduling, concurrency
  groups, cost expectations.
