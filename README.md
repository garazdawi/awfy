# Are We Fast Yet — BEAM continuous benchmarking

Mix project porting [Are We Fast Yet (AWFY)](https://github.com/smarr/are-we-fast-yet)
to **Erlang and Elixir**, with the surrounding infrastructure to run the
suite continuously across OTP commits and platforms.

Two layered concerns live here:

1. **The benchmarks.** All 14 AWFY benchmarks ported twice — once in Erlang,
   once in Elixir — preserving the original algorithms and data structures
   so the BEAM numbers compare cleanly against the upstream Ruby/JS/JVM
   ports.
2. **The infrastructure.** Mix tasks and a GitHub Actions workflow that
   measure every relevant `erlang/otp` master commit on Linux + Windows
   in CI, plus a cross-platform `mix awfy.fill` task that lets any local
   machine (M5, Windows VM, ARM Linux box) backfill the remaining columns
   on its own schedule. Results publish to `gh-pages` as a static HTML
   dashboard.

Live dashboard: https://garazdawi.github.io/awfy/ (once Pages is enabled
on the published `gh-pages` branch).

## What lives here

```
awfy/
├── src/                           # 14 Erlang benchmarks + SOM Vector helpers
├── lib/awfy/benchmarks/           # 14 Elixir benchmarks
├── lib/awfy/                      # framework: BencheeRunner, PeerRunner,
│   │                              #            Compare.Data, Fill.Diff,
│   │                              #            Measure.Helpers, Preflight.Parse
│   ├── compare/                   # cross-version dashboard data + math
│   ├── fill/                      # platform diff for `mix awfy.fill`
│   ├── measure/                   # label/run-dir naming
│   └── preflight/                 # OS-specific stability parsers
├── lib/mix/tasks/                 # awfy.{benchee,measure,compare,diff,fill,preflight}
├── bin/                           # install-otp-source.sh / -windows.ps1 /
│                                  # measure-versions (asdf sweep)
├── test/                          # 165 ExUnit tests
├── .github/workflows/             # bench.yml (prod), bench-test.yml (Phase-0),
│                                  # reuse.yml (license compliance)
├── upstream/                      # AWFY source (submodule, reference only)
├── *.md                           # plan docs — see "Documentation" below
└── mix.exs
```

## Mix tasks

| Task                  | Purpose |
|-----------------------|---------|
| `mix awfy.benchee`    | Interactive Benchee runner, the inner-loop tool when you're tuning a JIT change. |
| `mix awfy.measure`    | Record one OTP+Elixir version's numbers under `results/<run-dir>/`. Runs the preflight gate first. |
| `mix awfy.compare`    | Generate the static HTML dashboard from `results/`. |
| `mix awfy.diff`       | Console two-label delta with per-benchmark % change and a suite geomean. |
| `mix awfy.fill`       | Cross-platform: read `gh-pages`, find `(SHA, platform, flavor)` tuples missing for the current host, run them locally, commit (no push). |
| `mix awfy.preflight`  | System check for Low-Power-Mode, Spotlight, swap pressure, CPU governor, etc. |

Run `mix help awfy.<task>` for the full option list.

## How to use it

### Compare two OTP versions on your local machine

```sh
asdf shell erlang 27.3.4.11
mix awfy.measure --label otp27

asdf shell erlang 28.5.0
mix awfy.measure --label otp28

mix awfy.diff otp27 otp28          # console summary
mix awfy.compare && open results/index.html   # browser dashboard
```

### Sweep across asdf-managed versions in one go

```sh
bin/measure-versions 27.3.4.11 28.5.0 master
```

### Tune a JIT change

```sh
mix awfy.benchee Bounce            # one benchmark, both langs, ~30s
mix awfy.benchee --lang erlang     # all benchmarks, Erlang only
mix awfy.benchee Bounce --time 1 --warmup 0  # quick iterations
```

### Pick up missing measurements from CI (M5 / Windows VM / Linux ARM box)

```sh
mix awfy.fill                      # find missing SHAs, run, commit locally
mix awfy.fill --max 3              # cap to N runs per invocation
mix awfy.fill --dry-run            # show what would run, do nothing
git -C _pages push origin gh-pages # publish when satisfied (operator action)
```

`mix awfy.fill` was built so non-Linux runners can stay out of the cloud
matrix — Linux + Windows publish from CI, then any human-driven box fills
in its slice on its own schedule. See [`FILL_TASK_PLAN.md`](FILL_TASK_PLAN.md).

## Run-dir layout

Every `mix awfy.measure` invocation writes one directory:

```
results/<timestamp>_otp<v>_elixir<v>_<label>/
├── meta.json         # OTP/Elixir versions, machine + CPU info, runtime knobs,
│                     #   git SHA + dirty flag, per-benchmark source SHA256
├── Bounce.benchee    # one Benchee save per benchmark
├── Havlak.benchee
└── …
```

`meta.json` is what the dashboard reads to detect inner-iter / machine /
source-code mismatches across loaded saves and surface them as warnings.
The two-pass design (verify, then time) means a regression in one of
(Erlang, Elixir) doesn't invalidate the other — failing scenarios get
marked `verified: false` in `meta.json` and skipped in the timing pass.

## Per-benchmark VM isolation

Each benchmark scenario runs in a fresh BEAM peer node (`Awfy.PeerRunner`,
`:peer.start_link` over `:standard_io`). This eliminates cross-benchmark
variance from one scenario warming up Mnesia / crypto NIFs / ETS tables
for the next. Adds ~3 min to a full sweep; see
[`ISOLATION_POLICY.md`](ISOLATION_POLICY.md) for the cost/benefit
analysis. Override with `AWFY_NO_ISOLATION=1` for ad-hoc work.

## CI architecture

```
   master push ───►  ┌──────────────────────────┐
                     │ GitHub Actions matrix    │
                     │  build-linux-x86 (free)  │ ── docker push ───► GHCR
                     │  build-linux-arm (free)  │ ── docker push ───► GHCR
                     │  measure-linux-x86       │ ── docker run on AWS CodeBuild
                     │  measure-linux-arm       │ ── docker run on AWS CodeBuild
                     │  measure-windows         │ ── installer on AWS CodeBuild
                     │  publish (gh-pages)      │ ── push run-dirs + dashboard
                     └──────────────────────────┘
                                                ▲
                       user, on M5 ─► mix awfy.fill ──┘
```

Linux is the cadence (CI on every relevant master commit); macOS joins
later via local fill; Windows is in the CI matrix today but could move
to local-fill if CodeBuild's per-minute markup becomes annoying.

`bench-test.yml` is a parallel workflow that runs the same matrix on
free GHA-hosted runners — it validates the wiring end-to-end without
spending an AWS dollar. Use it before promoting to `bench.yml` against
CodeBuild. Numbers from hosted runners are too noisy for regression
detection; this is for pipeline correctness only.

See [`CLOUD_BENCH_PLAN.md`](CLOUD_BENCH_PLAN.md) and
[`SETUP.md`](SETUP.md) for the AWS / CodeBuild setup the repo owner
does once.

## The 14 benchmarks

| Benchmark   | Verify result | Notes |
|-------------|---------------|-------|
| Bounce      | 1331 | |
| List        | 10 | Custom `Element` record/struct |
| Mandelbrot  | InnerIter-dependent (1→128, 500→191, 750→50) | |
| NBody       | InnerIter-dependent, bit-exact at 250000 | |
| Permute     | 8660 | |
| Queens      | 8-queens × 10 | |
| Richards    | bit-exact: queue_count=23246, hold_count=9297 | |
| Sieve       | 669 (primes ≤ 5000) | |
| Storage     | 5461 (depth-7 tree) | |
| Towers      | 8191 = 2¹³ − 1 | |
| Json        | self-contained parser, 25 KB embedded test string | |
| DeltaBlue   | constraint solver (chain_test + projection_test) | |
| Havlak      | union-find loop recognizer; bit-exact at iter 1/15/150/1500/15000 | |
| CD          | custom red-black tree, voxel collision detection | |

Plus shared SOM `Vector` infrastructure (`src/awfy_som_vector.erl`,
`lib/awfy/som/vector.ex`) used by the polymorphic-heavy benchmarks.

## Cross-language snapshot

Single-shot times via `inner_benchmark_loop(N)` with `N` from
`upstream/rebench.conf`. Apple M5, OTP 28.4.1 + Elixir 1.19.5, Ruby 3.3.0,
no YJIT. Lower is better. Snapshot — for current/live numbers see the
dashboard.

| Benchmark   | Iter   | Erlang ms | Elixir ms | Ruby ms | Erlang vs Ruby |
|-------------|-------:|----------:|----------:|--------:|---------------:|
| Bounce      |  1500  |    85     |    89     |   542   | **6.4× faster** |
| List        |  1500  |    35     |    91     |   653   | **18.7× faster** |
| Mandelbrot  |   500  |   160     |   163     |   597   | 3.7× faster |
| NBody       | 250000 |   270     |   344     |   888   | 3.3× faster |
| Permute     |  1000  |   145     |   153     |   708   | 4.9× faster |
| Queens      |  1000  |    90     |   130     |   599   | 6.7× faster |
| Sieve       |  3000  |  1999     |  1369     |   952   | **0.48× (slower)** |
| Storage     |  1000  |   199     |    73     |   554   | 2.8× faster |
| Towers      |   600  |    63     |    55     |   668   | **10.6× faster** |
| Richards    |   100  |   491     |  1122     |  1743   | 3.5× faster |
| Json        |   100  |    46     |    73     |   466   | **10.1× faster** |
| CD          |   250  |   464     |   516     |  1127   | 2.4× faster |
| DeltaBlue   | 12000  |  1489     |  1442     |   208   | **0.14× (much slower)** |
| Havlak      |  1500  |   641     |   647     |  1177   | 1.8× faster |

Geomean: Erlang ~3.0× faster than Ruby, Elixir ~2.7× faster.

### What the numbers say

**Where the BEAM JIT shines (>5× over Ruby)**: List, Towers, Json,
Bounce, Queens — code that's loop-heavy, allocates record/tuple values,
and benefits cleanly from the JIT specialising on shape.

**Where Ruby beats us (Sieve, DeltaBlue):**

- **Sieve** is `:array` ops on a 5000-element flag table. Ruby's mutable
  `Array#[i]=` is a single store; our persistent `:array` rewrites a
  HAMT path log-N times per write. A flat 5000-tuple with `setelement/3`
  ran 25× slower (the destructive-update optimization didn't fire across
  the recursion); see `awfy_sieve.erl`. Closing the gap likely needs
  `:atomics`/`:counters`, which breaks the persistent-semantics rule.
- **DeltaBlue** is the worst: 7× behind Ruby. Mutation-heavy graph
  carried in `world` maps keyed by id — every "object access" is a
  `maps:get`, every "field write" a `maps:put`. MRI does these as direct
  pointer writes. The structural overhead is the price of immutability;
  closing the gap needs either tuple-of-records with destructive
  `setelement` (and verifying the JIT optimization actually fires) or a
  rule-breaking process-dictionary approach.

### Erlang vs Elixir

| Benchmark   | Erlang | Elixir | Elixir vs Erlang |
|-------------|-------:|-------:|-----------------:|
| List        |    35  |    91  | **2.6× slower** |
| Richards    |   491  |  1122  | **2.3× slower** |
| Storage     |   199  |    73  | **2.7× faster (!)** |
| NBody       |   270  |   344  | 1.3× slower |
| Sieve       |  1999  |  1369  | 1.5× faster |
| (others)    |        |        | within ~10% |

**List** and **Richards** punish Elixir's struct field access (atom-keyed
maps with hash-and-lookup) against Erlang records (positional `element/2`
reads, one instruction). **Storage** likely catches a faster
`Tuple.duplicate(nil, n)` allocator path than `:erlang.make_tuple` for
that exact shape — needs investigation.

## Optimization pass — Phase 2 findings

After Phase 1 (correctness), one pass over the 14 benchmarks for
idiomatic improvements. Highlights:

- **DeltaBlue chain_test** had `lists:nth(I+1, Vars)` per iteration
  (O(N²) over 12000 vars). Replaced with pairwise `[V1, V2 | Rest]`
  pattern match on the chain — O(N). 1864 → 1431 ms (~23% faster).
- **CD `is_in_voxel`**: Ruby relies on IEEE 754 ±Infinity when motion
  has zero Δx; Erlang's `/` crashes on /0, and substituting 0.0 made
  the predicate vacuously true, exploding the recursion (8 sec for
  inner=2 vs 1 ms after fix).
- **Sieve tuple-store** experiment (above) — kept `:array`.

Open items for the next pass — see [`PROGRESS.md`](PROGRESS.md). Notable:
detect when in-place tuple/binary update optimisations actually fire
in hot paths (`setelement_inplace`, writable binary), so the
DeltaBlue/Havlak/CD id-keyed-map structures can be safely restructured
as tuple-of-records.

## Documentation

- [`PORT_PLAN.md`](PORT_PLAN.md) — original port plan, per-benchmark notes.
- [`PROGRESS.md`](PROGRESS.md) — Phase 2 optimization checklist.
- [`BENCH_VERSIONS_PLAN.md`](BENCH_VERSIONS_PLAN.md) — design behind
  `mix awfy.measure` / `mix awfy.compare` / `mix awfy.diff`.
- [`CLOUD_BENCH_PLAN.md`](CLOUD_BENCH_PLAN.md) — CI architecture, AWS
  CodeBuild rationale, cost analysis.
- [`SETUP.md`](SETUP.md) — one-time setup for the workflow operator.
- [`FILL_TASK_PLAN.md`](FILL_TASK_PLAN.md) — `mix awfy.fill` design.
- [`ISOLATION_POLICY.md`](ISOLATION_POLICY.md) — per-benchmark peer-node
  isolation rationale.
- [`LICENSING_POLICY.md`](LICENSING_POLICY.md) — REUSE compliance, mixed
  AWFY-MIT / framework-Apache-2.0.
- [`EXTENDED_BENCH_PLAN.md`](EXTENDED_BENCH_PLAN.md) — planned mnesia
  TPC-B / ETS / scheduler-stress / message-passing families
  (not implemented).
- [`NETWORK_BENCH_PLAN_TIER1.md`](NETWORK_BENCH_PLAN_TIER1.md) — planned
  single-host network ladder (not implemented).

## Tests

```sh
mix test
# 165 tests, 0 failures
```

Coverage: every benchmark has a verify-result test (Erlang + Elixir);
plus unit tests for `Awfy.PeerRunner`, `Awfy.BencheeRunner`,
`Awfy.Compare.Data`, `Awfy.Fill.Diff`, `Awfy.Measure.Helpers`, and
`Awfy.Preflight.Parse`.

## License

- Original framework code (Mix tasks, modules under `lib/awfy/` other
  than `benchmarks/`, scripts under `bin/`): **Apache-2.0**, copyright
  Lukas Backström.
- Ported AWFY benchmarks (`src/awfy_*.erl`, `lib/awfy/benchmarks/*.ex`,
  `lib/awfy/som/`): **MIT**, attributed to Stefan Marr (upstream).
- All files carry SPDX headers; the repo is REUSE-compliant. CI enforces
  this via `.github/workflows/reuse.yml`.

See [`LICENSING_POLICY.md`](LICENSING_POLICY.md).
