<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# Extended Bench Plan — non-network OTP benchmarks

Companion to `BENCH_VERSIONS_PLAN.md`, `CLOUD_BENCH_PLAN.md`, and
`NETWORK_BENCH_PLAN_TIER1.md`. Extends the awfy framework beyond the
AWFY cross-language compute suite to track regressions in BEAM-internal
operations: BIFs, NIFs, maps, hashes, Mnesia transactions, and the
canonical `estone` synthetic load. None of these benchmarks are
network-shaped — every one runs in a single BEAM on a single host.

## Why these and not the AWFY suite

The AWFY ports we already ship cover pure compute over portable data
structures (lists, integers, floats, dictionaries) — they're great
for cross-language comparison and for catching JIT / compiler
regressions on tight loops. They cover *almost nothing* about
BEAM-specific operations that production code actually leans on:

- The `phash2` BIF appears in every ETS lookup, every `dict`/`gb_set`,
  and the message scheduler. A regression there shows up *everywhere*
  — but the AWFY suite never calls `phash2`.
- ETS underpins almost every long-lived OTP application (registry,
  Phoenix LiveView PubSub, gen_server-backed caches, dets). Its
  contention story (CA tree on `ordered_set`, `read_concurrency`,
  `write_concurrency`) is a flagship BEAM perf feature with no
  counterpart elsewhere — and AWFY never touches it.
- Maps have changed significantly across OTP versions (small-map vs
  HAMT thresholds, JIT opcodes). AWFY uses lists and tuples almost
  exclusively.
- Mnesia's transaction throughput is a load-bearing OTP capability,
  unique to BEAM, that nobody else benchmarks.
- `estone` is OTP's own canonical "is BEAM faster?" number, in use
  for two decades. We should be tracking it.

## Scope (Tier 1)

In: every benchmark below runs in a **single BEAM process tree on a
single host**, no namespaces, no second machine, no external
services. CI cost is roughly free since they slot into the existing
Linux/macOS/Windows matrix without new AWS resources.

Out (deferred):
- Multi-node Mnesia TPC-B (replication layer) — needs the same
  two-host plumbing as the deferred Tier 2 network work.
- `ssl_bench_SUITE`, `ssh_bench_SUITE`, `httpd_bench_SUITE` —
  network-shaped, covered by `NETWORK_BENCH_PLAN_TIER1.md`.
- `prof_bench_SUITE` — needs ~16 GB scratch disk and measures the
  profiler itself, not BEAM perf. Not a regression signal.
- ASN.1 decode perf — narrow audience, skip.
- `interpreter_size_bench` — measures binary footprint, not
  throughput. Different category, different reporting.

## Benchmark inventory

Effort estimates: wall-clock for one experienced engineer.

| # | Source suite | Benchmark | What it stresses | Effort |
|---|--------------|-----------|------------------|--------|
| 1 | `hash_SUITE` | `phash2_benchmark_tests` | `erlang:phash2/2` on ints, binaries, maps, tuples, lists at multiple sizes | low — pull `phash2_benchmark_tests` group, wrap each input type as a Benchee scenario |
| 2 | `map_SUITE` | `benchmarks` | construction / access / update / merge / iteration on maps from N=1 to N=10000, crossing the small-map → HAMT threshold | low |
| 3 | `binary_SUITE` | `iolist_size_benchmarks` | `iolist_size/1` on shallow / deep / huge iolists, including the trap-yield case | low |
| 4 | `stdlib_bench_SUITE` | `base64` group | `base64:encode/decode_to_string` on bins/lists, MIME variants | low |
| 5 | `stdlib_bench_SUITE` | `binary` group | `binary:match` / `binary:matches` no-match, eventual, frequent | low |
| 6 | `stdlib_bench_SUITE` | `unicode` group | `string:to_graphemes`, `unicode:characters_to_nfc_*`, `string:lexemes` | low |
| 7 | `crypto_bench_SUITE` | `textblock_256` (`ciphers_128/256`, `chacha20`) | block + stream cipher throughput; isolates NIF dispatch overhead from JIT noise | low — port suite to drive Benchee, drop the cipher-loop scaffolding |
| 8 | `ets_SUITE` (stdlib) | `throughput_benchmark` family — see ETS section below | concurrent ETS reads/writes, CA-tree path on `ordered_set`, table-type matrix, key-type matrix | medium — wrap the existing throughput_benchmark, but pick a focused subset rather than running the whole 100-config matrix |
| 9 | `estone_SUITE` | each `micros/0` entry as its own scenario | wide-spectrum: lists, msgp, pattern matching, BIF dispatch, ETS, int/float arith, generic, large datasets | medium — ~25 micros, each ~30 LoC of wrapping |
| 10 | `mnesia_bench_SUITE` + `lib/mnesia/examples/bench/` | TPC-B `ram_copies` only, single-node | full Mnesia transaction throughput: fragmenter, lock manager, allocator under sustained load | medium-high — re-host the standalone bench under our framework |
| 11 | `mnesia_bench_SUITE` | TPC-B `disc_only_copies`, single-node | adds disk I/O and dets — different perf profile, useful for catching disk-path regressions | medium — same wrapper as #10, different storage type |

**Total**: 10 benchmark families (plus ~25 estone micros = effectively
~40 distinct scenarios). All slot into the existing CI matrix.

## Code structure

Final layout (deviates from the original plan's `lib/awfy/extended/`
sketch — the suite app sits under `apps/` for the same reason
AWFY does, plus the licensing split makes `apps/otp_benchmarks/` a
clean Apache-2.0 boundary against the MIT-licensed `apps/awfy/`):

```
apps/otp_benchmarks/
├── mix.exs
└── lib/
    ├── otp_benchmarks.ex             # OtpBenchmarks (registry)
    └── otp_benchmarks/
        ├── benchmark.ex              # OtpBenchmarks.Benchmark (behaviour)
        └── benchmarks/
            ├── phash2.ex             # ✅ first family
            ├── maps.ex
            ├── iolist_size.ex
            ├── base64.ex
            ├── binary_match.ex
            ├── unicode_norm.ex
            ├── crypto_aes.ex
            ├── ets/
            │   ├── single_scheduler.ex
            │   ├── concurrency.ex
            │   ├── update.ex
            │   ├── bulk.ex
            │   ├── key_types.ex
            │   └── catree_init.ex
            ├── mnesia/
            │   ├── tpcb_ram.ex
            │   ├── tpcb_disc_only.ex
            │   └── support.ex
            └── estone/
                ├── lists.ex
                ├── msgp.ex
                ├── pattern.ex
                └── …

lib/awfy/otp_benchmarks/
└── runner.ex                         # Awfy.OtpBenchmarks.Runner
                                      # (orchestration, peer/in-process
                                      # dispatch, save shape)

lib/mix/tasks/
└── awfy.measure.ex                   # extended in-place to run both
                                      # suites; no separate task.
```

The `OtpBenchmarks.Benchmark` behaviour mirrors `Awfy.Benchmark` but
adds:

- `setup/1` returning a context (e.g. populated map, opened mnesia
  schema, NIF resource handle).
- `teardown/1` for cleanup (`mnesia:stop()`, etc.).

Benchee's `:before_scenario` / `:after_scenario` hooks invoke these
once per scenario; `:before_each` / `:after_each` are reserved for
per-iteration state if a benchmark needs it (most don't).

For benchmarks that share inputs across many scenarios (e.g. the same
phash2 input table tested under different inner_iter), the context
is built once per scenario and re-used per iteration — keeps the
timed loop tight.

## Mix task

There is no separate `mix awfy.measure_extended` task — the original
plan called for one but the unified `mix awfy.measure` flow turned
out cleaner: every fill / sweep automatically picks up both suites
without GHA changes, and the dashboard run-dirs hold both suites'
data side by side.

```
mix awfy.measure                                  # AWFY + every OtpBenchmarks family
mix awfy.measure --benchmarks Bounce,phash2       # mixed filter — AWFY + OtpBenchmarks
mix awfy.measure --benchmarks phash2              # OtpBenchmarks only
mix awfy.measure --no-otp-benchmarks              # AWFY only (legacy / debug)
```

Reuses `results/<run-dir>/` save shape so `mix awfy.compare`
generates the dashboard with no changes. Run-dirs hold one
`<family>.benchee` per OtpBenchmarks family alongside the AWFY
`<benchmark>.benchee` files.

## CI integration

No new jobs needed. `mix awfy.measure` runs the OtpBenchmarks
suite as part of every existing measure-* job (linux / macos /
windows × modern peer-flow), so the existing fill workflow picks
up the new data automatically:

```
gh workflow run bench.yml \
   -f otp_refs=fill \
   -f benchmarks=phash2     # filter to one family for targeted backfill
```

The resolve step's per-benchmark skip-check (`bin/resolve-fill-needs.sh`,
`INPUT_BENCHMARKS=phash2`) walks gh-pages's `<sha>-test-<plat>-*/phash2.benchee`
blobs and emits exactly the (sha × platform) pairs that don't yet
have phash2 data. The downstream measure jobs invoke
`mix awfy.measure --benchmarks phash2 …` against those, which in
turn dispatches OtpBenchmarks's `Awfy.OtpBenchmarks.Runner`. The
new `phash2.benchee` artifacts merge into gh-pages alongside the
existing AWFY `.benchee` files; the dashboard already knows how
to render the multi-input shape.

Bundle-target legs (OTP < 24) skip the OtpBenchmarks pass for now;
cross-OTP wiring lives at sequence step 9.

## ETS specifics

`stdlib`'s `ets_SUITE.erl` contains a `throughput_benchmark/{0,1}`
that drives a Cartesian matrix of (table-type × access-pattern ×
scheduler-count × `read_concurrency` × `write_concurrency` ×
key-distribution). Run uncut, it's ~100+ configurations and ~30
minutes per platform — overkill for daily CI. We pick a focused
subset that covers the real failure modes:

1. **Single-scheduler baseline, all 4 table types**: `set`,
   `ordered_set`, `bag`, `duplicate_bag` × { lookup-only,
   insert-only, 50/50 mixed }. 12 scenarios. Catches per-op cost
   regressions in the BIF dispatch path independent of locking.
2. **Multi-scheduler contention**: `set` + `ordered_set`, both with
   and without `read_concurrency: true` and `write_concurrency:
   true`, at scheduler counts 2 / N (where N = `schedulers_online`).
   Exercises the CA-tree path on `ordered_set` and the locking
   strategy on `set`. ~8 scenarios.
3. **Update path**: `update_counter/3` and `update_element/3` on
   `set`, single-scheduler — these are atomic-update opcodes the
   JIT specifically optimises for. 2 scenarios.
4. **Bulk operations**: `insert/2` with a 1000-element list,
   `select/2` against a known-row pattern, `match/2` against a
   wildcard pattern. 3 scenarios.
5. **Key-type matrix**: lookup on `set` with integer / atom / tuple
   / binary keys — different hash + compare costs. 4 scenarios.

That's ~29 ETS scenarios — comparable in volume to estone, distinct
in coverage. Run them in a dedicated `ets` benchmark family
(`lib/awfy/extended/benchmarks/ets/<flavor>.ex`) so they can be
toggled with `mix awfy.measure_extended --benchmarks ets`.

The `lookup_catree_par_vs_seq_init_benchmark` is interesting — it
specifically measures the parallel-vs-sequential init path on
`ordered_set`, which is a known regression hotspot. Add as a
separate `ets_catree_init` scenario.

## Mnesia TPC-B specifics

TPC-B is a debit-credit OLTP workload with a known
contention-skewed access pattern (1% of "branches" gets 85% of
traffic, the rest of the world is uniform). Three concrete decisions
for our port:

1. **Single-node only in v1.** Multi-node tpcb measures
   distribution + replication; that's a different benchmark class
   and belongs with the Tier 2 network work. We use `local_only`
   mode (the existing `bench.erl` flag) which still exercises the
   Mnesia transaction manager, lock manager, and storage backend
   — just not the replication layer.
2. **Both `ram_copies` and `disc_only_copies`.** RAM is the clean
   CPU/lock signal. `disc_only_copies` adds dets I/O, which is
   noisy on cloud SSDs but catches regressions in the disk path.
   Mark `disc_only_copies` results as advisory until we see how
   stable they are; expected CV is 10-20% vs ~3% for ram.
3. **Pre-populate the database during `setup_scenario`, time only
   the transaction loop.** Schema creation + record load is ~5-10
   minutes for a meaningful working set; we don't want that in the
   timed window. Per-iteration: fixed-size batch of TPC-B
   transactions, measure latency + throughput. Save the populated
   schema to disk and reuse across the run if the benchmark allows.

The existing `lib/mnesia/examples/bench/bench.erl` already supports
single-node `local_only` mode — most of the porting work is
adapting its run loop to be Benchee-driven (one transaction batch
per Benchee iteration) rather than CLI-driven.

## Open questions

1. **Estone's composite score.** Upstream `estone` produces a single
   "ESTONES" number. Do we report (a) the composite, (b) per-micro
   numbers only, or (c) both? Answer: (c). Per-micro for diagnosis,
   composite for the canonical headline figure.
2. **Crypto NIF cipher choice.** AES-128-GCM, AES-256-GCM,
   ChaCha20-Poly1305, and a no-op cipher (XOR) — the no-op
   isolates NIF dispatch overhead from the actual crypto cost.
   Run all four as separate scenarios.
3. **`disc_only_copies` flakiness threshold.** If CV stays above
   25% across the first month of runs, drop it from the default
   set and gate it behind `--include-flaky`.
4. **Estone scaling factor.** Upstream estone hardcodes iteration
   counts that produce ~30 seconds of work on a *2002-era* machine;
   on modern hardware they finish in ~10ms with ~3% CV. Bump the
   inner counts so per-micro window is ≥1s — done as a one-time
   calibration during the port.
5. ~~**Mnesia's effect on subsequent benchmarks in the same run.**~~
   Resolved by `../ISOLATION_POLICY.md` — every benchmark gets its
   own fresh peer node, so Mnesia ordering within a sweep is
   irrelevant.

## Sequence

1. ✅ **Spike**: port `phash2_benchmark_tests` + write
   `OtpBenchmarks.Benchmark` behaviour. Lives at
   `apps/otp_benchmarks/` (separate from AWFY for the licensing
   split — see ARCHITECTURE.md). Runner at
   `Awfy.OtpBenchmarks.Runner` dispatches via the shared peer-flow.
2. ✅ **Dashboard data model**: `Awfy.Compare.Data` carries
   `scenario.input_name` as a separate `input` field, sub-μs
   medians preserved at 6-decimal precision, multi-input rows
   excluded from the suite-wide geomean. Dashboard JS renders
   multi-input families as multi-series charts driven by an
   "Input" checkbox group (see `priv/dashboard.js` `seriesAxis`).
3. ✅ **Measure integration**: `mix awfy.measure` runs both AWFY
   and OtpBenchmarks suites in one pass. `--benchmarks <list>`
   filters across both by family name; `--no-otp-benchmarks` opts
   out. `meta.json` carries an `otp_benchmarks` block parallel to
   the existing `benchmarks` block. Bundle-target mode skips the
   OtpBenchmarks pass automatically (cross-OTP wiring → step 8).
4. Port the rest of Tier 1 (#2-#7): maps, iolist_size, base64,
   binary:match, unicode, crypto AES. ~1 day each.
5. Port ETS (#8). Start with single-scheduler scenarios (12), add
   the concurrency matrix (8) once those are stable, then update /
   bulk / key-type / catree_init. ~3-4 days total.
6. Port estone (~25 micros). The micros all share a tight common
   shape so this is more wrap-paste than thinking.
7. Port mnesia TPC-B `ram_copies`. Build the single-node setup
   helper first (schema + populate); the transaction-loop wrapper
   is short.
8. Port mnesia TPC-B `disc_only_copies`. Should be a one-line diff
   from #7 once the framework exists.
9. Cross-OTP wiring for OtpBenchmarks: extend the target bundle
   path so OTP < 24 measure jobs produce phash2/ETS/etc. data
   (today they only emit AWFY). Touches
   `apps/awfy_target_runner/`, `bin/install-otp-source-mac.sh`,
   `Dockerfile.linux`, and `bin/build-target-bundle.sh`.
10. Per-benchmark `:time` calibration pass — same pattern as the
    compute calibration we did for AWFY.

## Why not …

- **Run estone as the existing single composite test** — losing per-
  micro visibility means a regression in *one* subsystem (e.g. ETS)
  shows up as a 4% composite drop with no signal about where.
- **Multi-node mnesia tpcb in v1** — same reason as the network
  Tier 1 plan: the network noise floor swamps the signal we want.
- **Skip mnesia entirely** — it's the largest production OTP
  capability nobody else benchmarks, and a regression there *will*
  matter to real users. Worth the porting effort.
- **Add gen_server / gen_statem benchmarks here** — they're already
  in the network Tier 1 plan as the intra-node case (gen_server
  call latency *is* the IPC-shaped benchmark of OTP behaviours).
  Don't double-port.
