<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

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
├── apps/                          # benchmark suites — each independently
│   │                              # compilable with its own mix.exs and a
│   │                              # low Elixir floor, so older OTPs can
│   │                              # still build them.
│   └── awfy/                      # AWFY suite (Stefan Marr's port, MIT)
│       ├── mix.exs
│       ├── src/                   # 14 Erlang benchmarks + SOM helpers
│       ├── lib/awfy.ex            # registry + verify
│       ├── lib/awfy/benchmark.ex  # behaviour
│       ├── lib/awfy/benchmarks/   # 14 Elixir benchmarks
│       └── priv/                  # benchmark inputs (rap_benchmark.json)
├── lib/awfy/                      # runner: orchestration only
│   ├── benchee_runner.ex          # Benchee + isolation
│   ├── peer_runner.ex             # peer mgmt
│   ├── compare/                   # cross-version dashboard data + math
│   ├── fill/                      # platform diff for `mix awfy.fill`
│   ├── measure/                   # label/run-dir naming
│   └── preflight/                 # OS-specific stability parsers
├── lib/mix/tasks/                 # awfy.{benchee,measure,compare,diff,fill,preflight}
├── patches/                       # OTP-source patches per major
├── bin/                           # install-otp-source-mac.sh / -windows.ps1 /
│                                  # measure-versions (asdf sweep)
├── test/                          # 165 ExUnit tests
├── .github/workflows/             # bench.yml (push/schedule/dispatch with
│                                  # runner_pool=gha|aws), reuse.yml,
│                                  # shellcheck.yml
├── upstream/                      # AWFY source (submodule, reference only)
├── *.md                           # plan docs — see "Documentation" below
└── mix.exs                        # runner project (`:awfy_runner`),
                                   # path-deps on each apps/<group>/
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
in its slice on its own schedule. See [`PLAN/FILL_TASK_PLAN.md`](PLAN/FILL_TASK_PLAN.md).

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
                     │  measure-linux-x86       │ ── docker run on EC2 c6i.4xlarge
                     │  measure-linux-arm       │ ── docker run on EC2 c7g.4xlarge
                     │  measure-windows         │ ── installer on EC2 c6i.4xlarge+Win
                     │  publish (gh-pages)      │ ── push run-dirs + dashboard
                     └──────────────────────────┘
                                                ▲
                       user, on M5 ─► mix awfy.fill ──┘
```

Linux is the cadence (CI on every relevant master commit); macOS joins
later via local fill; Windows is in the CI matrix today but could move
to local-fill if cloud spend becomes annoying.

The cloud runners are ephemeral EC2 instances managed by Terraform
(`terraform/`) via the `philips-labs/terraform-aws-github-runner`
module — pinned to `c6i.4xlarge` (Linux x86 + Windows) and
`c7g.4xlarge` (Linux ARM Graviton 3) so trend lines hold up across
years.

`bench.yml` accepts a `runner_pool` workflow_dispatch input (`gha` /
`aws`, default `gha`) and the push trigger pins it to `gha`. Free
GHA-hosted runs validate the wiring end-to-end without spending an
AWS dollar; `aws` flips the measure jobs onto the Terraform-managed
EC2 pools. Numbers from hosted runners are too noisy for regression
detection — use the GHA pool for pipeline correctness, `aws` for
publishable measurements.

See [`PLAN/CLOUD_BENCH_PLAN.md`](PLAN/CLOUD_BENCH_PLAN.md) and
[`SETUP.md`](SETUP.md) for the AWS / Terraform setup the repo owner
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

Plus shared SOM `Vector` infrastructure (`apps/awfy/src/awfy_som_vector.erl`,
`apps/awfy/lib/awfy/som/vector.ex`) used by the polymorphic-heavy benchmarks.

Cross-language and cross-version numbers will land on the dashboard
once the cloud sweep starts publishing — running locally on a
developer machine isn't reliable enough to quote in the README.

## Optimization pass — Phase 2 findings

After Phase 1 (correctness), one pass over the 14 benchmarks for
idiomatic improvements. Highlights:

- **DeltaBlue chain_test** had `lists:nth(I+1, Vars)` per iteration
  (O(N²) over 12000 vars). Replaced with pairwise `[V1, V2 | Rest]`
  pattern match on the chain — O(N), measured ~23% faster.
- **CD `is_in_voxel`**: Ruby relies on IEEE 754 ±Infinity when motion
  has zero Δx; Erlang's `/` crashes on /0, and substituting 0.0 made
  the predicate vacuously true, exploding the recursion (8 sec for
  inner=2 vs 1 ms after fix).
- **Sieve flat-tuple experiment**: replaced the `:array` flag table
  with a 5000-element tuple expecting BEAM's destructive-update
  optimization to kick in across the recursion. It didn't — ran
  ~25× slower. Reverted; closing the gap likely needs
  `:atomics`/`:counters`, which breaks persistent semantics. See
  `apps/awfy/src/awfy_sieve.erl`.

Open items for the next pass — see [`PROGRESS.md`](PROGRESS.md). Notable:
detect when in-place tuple/binary update optimisations actually fire
in hot paths (`setelement_inplace`, writable binary), so the
DeltaBlue/Havlak/CD id-keyed-map structures can be safely restructured
as tuple-of-records.

## Documentation

- [`PLAN/PORT_PLAN.md`](PLAN/PORT_PLAN.md) — original port plan, per-benchmark notes.
- [`PROGRESS.md`](PROGRESS.md) — Phase 2 optimization checklist.
- [`PLAN/BENCH_VERSIONS_PLAN.md`](PLAN/BENCH_VERSIONS_PLAN.md) — design behind
  `mix awfy.measure` / `mix awfy.compare` / `mix awfy.diff`.
- [`PLAN/CLOUD_BENCH_PLAN.md`](PLAN/CLOUD_BENCH_PLAN.md) — CI architecture,
  Terraform-runner rationale, cost analysis.
- [`SETUP.md`](SETUP.md) — one-time setup for the workflow operator.
- [`PLAN/FILL_TASK_PLAN.md`](PLAN/FILL_TASK_PLAN.md) — `mix awfy.fill` design.
- [`ISOLATION_POLICY.md`](ISOLATION_POLICY.md) — per-benchmark peer-node
  isolation rationale.
- [`LICENSING_POLICY.md`](LICENSING_POLICY.md) — REUSE compliance, mixed
  AWFY-MIT / framework-Apache-2.0.
- [`PLAN/EXTENDED_BENCH_PLAN.md`](PLAN/EXTENDED_BENCH_PLAN.md) — planned mnesia
  TPC-B / ETS / scheduler-stress / message-passing families
  (not implemented).
- [`PLAN/NETWORK_BENCH_PLAN_TIER1.md`](PLAN/NETWORK_BENCH_PLAN_TIER1.md) — planned
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

- Original runner code (Mix tasks, modules under `lib/awfy/`,
  scripts under `bin/`): **Apache-2.0**, copyright Lukas Backström.
- Ported AWFY benchmarks under `apps/awfy/`: **MIT**, attributed to
  Stefan Marr (upstream).
- All files carry SPDX headers; the repo is REUSE-compliant. CI enforces
  this via `.github/workflows/reuse.yml`.

See [`LICENSING_POLICY.md`](LICENSING_POLICY.md).
