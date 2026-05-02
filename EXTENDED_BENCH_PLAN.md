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
| 8 | `estone_SUITE` | each `micros/0` entry as its own scenario | wide-spectrum: lists, msgp, pattern matching, BIF dispatch, ETS, int/float arith, generic, large datasets | medium — ~25 micros, each ~30 LoC of wrapping |
| 9 | `mnesia_bench_SUITE` + `lib/mnesia/examples/bench/` | TPC-B `ram_copies` only, single-node | full Mnesia transaction throughput: fragmenter, lock manager, allocator under sustained load | medium-high — re-host the standalone bench under our framework |
| 10 | `mnesia_bench_SUITE` | TPC-B `disc_only_copies`, single-node | adds disk I/O and dets — different perf profile, useful for catching disk-path regressions | medium — same wrapper as #9, different storage type |

**Total**: 9 benchmark families (plus ~25 estone micros = effectively
~33 distinct scenarios). All slot into the existing CI matrix.

## Code structure

```
lib/awfy/extended/
├── benchmark.ex                  # behaviour for these benchmarks
└── benchmarks/
    ├── phash2.ex
    ├── maps.ex
    ├── iolist_size.ex
    ├── base64.ex
    ├── binary_match.ex
    ├── unicode_norm.ex
    ├── crypto_aes.ex
    └── estone/                   # one file per micros entry
        ├── lists.ex
        ├── msgp.ex
        ├── pattern.ex
        ├── …
        └── int_arith.ex

lib/awfy/extended/mnesia/
├── tpcb_ram.ex                   # single-node ram_copies TPC-B
├── tpcb_disc_only.ex             # single-node disc_only_copies
└── support.ex                    # shared schema + populate logic

lib/mix/tasks/
└── awfy.measure_extended.ex      # entry point — same shape as awfy.measure
```

The `Awfy.Extended.Benchmark` behaviour mirrors `Awfy.Benchmark` but
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

```
mix awfy.measure_extended                                 # all
mix awfy.measure_extended --benchmarks phash2,maps        # subset
mix awfy.measure_extended --skip-mnesia                   # the slow ones
mix awfy.measure_extended --estone-only                   # just the micros
```

Reuses `results/<run-dir>/` save shape so `mix awfy.compare`
generates the dashboard with no changes. Run-dir labels get an
`-ext-` infix to distinguish them from compute-suite runs:
`<sha>-ext-<flavor>` for Linux/macOS/Windows variants.

## CI integration

One new job per platform — no new AWS resources, just an extra row
on the existing matrix:

```yaml
measure-extended:
  needs: [resolve, build-linux]   # or installer / M5 path per platform
  strategy:
    fail-fast: false
    matrix:
      include:
        - { os: linux,   arch: x86_64, runner: codebuild-…, flavor: jit }
        - { os: linux,   arch: x86_64, runner: codebuild-…, flavor: emu }
        - { os: linux,   arch: arm64,  runner: codebuild-…, flavor: jit }
        - { os: linux,   arch: arm64,  runner: codebuild-…, flavor: emu }
        - { os: macos,   arch: arm64,  runner: [self-hosted, macos-m5], flavor: jit }
        - { os: macos,   arch: arm64,  runner: [self-hosted, macos-m5], flavor: emu }
        - { os: windows, arch: x86_64, runner: codebuild-…, flavor: jit }
        - { os: windows, arch: x86_64, runner: codebuild-…, flavor: emu }
  steps:
    - …pull image / install OTP per platform…
    - run: mix awfy.measure_extended --label …-ext-${{ matrix.flavor }}
    - uses: actions/upload-artifact@v4
```

8 added jobs (4 platforms × 2 flavors), each ~10-15 min. Cost:
~$0.40 / sweep, ~$145/yr daily. Same publish flow.

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
5. **Mnesia's effect on subsequent benchmarks in the same run.**
   Once mnesia has been started, its sup tree, schedulers' message
   queues, and the application controller's state are all warmer
   than they would be from a cold BEAM. Order mnesia *last* in the
   run so it doesn't perturb the pure-compute scenarios.

## Sequence

1. **Spike**: port `phash2_benchmark_tests` + write
   `Awfy.Extended.Benchmark` behaviour. Validates the framework
   handles BIF-driven scenarios with multiple input variants.
2. Port the rest of Tier 1 (#2-#7): maps, iolist_size, base64,
   binary:match, unicode, crypto AES. ~1 day each.
3. `mix awfy.measure_extended` task; verify save / load / compare
   integration with the existing dashboard.
4. Port estone (~25 micros). The micros all share a tight common
   shape so this is more wrap-paste than thinking.
5. Port mnesia TPC-B `ram_copies`. Build the single-node setup
   helper first (schema + populate); the transaction-loop wrapper
   is short.
6. Port mnesia TPC-B `disc_only_copies`. Should be a one-line diff
   from #5 once the framework exists.
7. Wire the GHA job; first sweep will be slow (cold images for the
   new measure task on every platform). Stabilise over 3-4 daily
   runs before judging numbers.
8. Per-benchmark `:time` calibration pass — same pattern as the
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
