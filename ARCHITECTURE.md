# Architecture

This document describes how the AWFY benchmarking system is organised:
where code lives, how a measurement flows from CI trigger to published
chart, and the seams designed for extension. It's the entry point for
"how does this all fit together?" — go to the linked docs for any single
piece in detail.

## Overview

The system runs a fixed set of benchmarks against many Erlang/OTP
versions, on multiple platforms, and publishes a cross-version dashboard.
Three forces shape the design:

* **Isolation**: every benchmark runs in a fresh BEAM so cross-bench
  warmup doesn't leak (Mnesia supervisor trees, ETS lazy-init, JIT
  cache state, etc.).
* **Reproducibility**: one OTP source SHA → one set of numbers, on a
  given platform. The orchestrator pins versions, hashes benchmark
  sources, and records a full machine fingerprint in `meta.json`.
* **Cross-version reach**: benchmarking OTP 20 from an OTP 28 runner
  means the orchestrator's Elixir/OTP can't dictate the target's
  Elixir/OTP. So we split: the runner stays on a modern host, the
  benchmarks compile and execute on the target.

These translate into a four-piece architecture:

```
┌───────────────────────────┐    ┌──────────────────────────────────┐
│    apps/<group>/          │    │  bin/install-otp-source.sh       │
│    benchmark suites       │    │  Dockerfile.linux                │
│    (awfy, otp, …)         │───▶│  build target OTP +              │
│    plain Erlang/Elixir    │    │  per-target beams                │
└──────────┬────────────────┘    └──────────────┬───────────────────┘
           │ path-dep                           │ AWFY_TARGET_BEAMS
           ▼                                    ▼
┌───────────────────────────┐    ┌──────────────────────────────────┐
│  Runner (this project)    │    │  Target VM (per-OTP)             │
│  • mix awfy.measure       │───▶│  awfy_target_runner:run_iters    │
│  • mix awfy.compare       │    │  pure Erlang, plain text out     │
│  • Awfy.{BencheeRunner,   │    └──────────────────────────────────┘
│    PeerRunner,            │
│    TargetRunner}          │
│  • dashboard renderer     │
└───────────┬───────────────┘
            │ writes .benchee + meta.json
            ▼
┌───────────────────────────────────────┐
│  results/ → gh-pages worktree →       │
│  HTML dashboard (Chart.js)            │
└───────────────────────────────────────┘
```

## Repository layout

```
awfy/
├── apps/                   # Benchmark suites — independently
│   │                       # compilable mix projects, low Elixir floor.
│   └── awfy/               # AWFY suite (Stefan Marr's port)
│       ├── mix.exs
│       ├── src/            # Erlang benchmarks + helpers
│       ├── lib/awfy/       # Elixir benchmarks + behaviour + registry
│       ├── priv/           # benchmark inputs (rap_benchmark.json)
│       └── src_target/     # plain-Erlang harness compiled per target
│
├── lib/                    # Runner project (`:awfy_runner`)
│   ├── awfy/
│   │   ├── benchee_runner.ex   # picks execution mode, runs Benchee
│   │   ├── peer_runner.ex      # same-OTP `:peer` orchestration
│   │   ├── target_runner.ex    # cross-OTP fork-and-parse
│   │   ├── compare/data.ex     # reads .benchee + meta.json
│   │   ├── fill/diff.ex        # `mix awfy.fill` planner
│   │   ├── measure/helpers.ex  # label / run-dir naming
│   │   └── preflight/parse.ex  # OS-specific stability checks
│   └── mix/tasks/
│       ├── awfy.measure.ex     # collect timings → .benchee + meta.json
│       ├── awfy.compare.ex     # aggregate runs → gh-pages HTML
│       ├── awfy.diff.ex        # ad-hoc speedup between two labels
│       ├── awfy.fill.ex        # fill missing rows on local machine
│       └── awfy.preflight.ex   # warn on noisy host (HFS encryption,
│                               # CPU governor, throttling, …)
│
├── patches/                # OTP-source patches per major
│   ├── README.md
│   └── OTP-<N>/*.patch
│
├── bin/                    # Build & install scripts
│   ├── install-otp-source.sh   # macOS + local: build target OTP from src
│   └── install-otp-windows.ps1 # Windows: download tag/CI installer
│
├── test/                   # ExUnit, 165 tests
├── .github/workflows/
│   ├── bench.yml           # production AWS sweep
│   ├── bench-test.yml      # GHA-hosted Phase-0 sweep
│   └── reuse.yml           # SPDX/REUSE compliance
│
├── Dockerfile.linux        # build target OTP + benchmark image
├── mix.exs                 # runner project; path-deps each suite
└── ARCHITECTURE.md         # ← you are here
```

## The two-tier project structure

### Why apps/ and not an umbrella

The benchmark suites and the runner have different version constraints:

* The **runner** uses modern Elixir features (1.16+) and orchestration
  libraries (Benchee, Jason). It's compiled and run on the host.
* The **suites** must compile against any OTP we want to benchmark, all
  the way back to OTP 20. They have no runtime deps and pin
  `elixir: ~> 1.14` so the per-target build path can use whichever
  Elixir is compatible with that OTP.

A Mix umbrella enforces a single dep tree and shared build, which works
against the cross-OTP build pipeline. Instead, each app sits under
`apps/<name>/` with its own `mix.exs`, and the runner's root `mix.exs`
declares `{:awfy, path: "apps/awfy"}` — a plain Mix path-dep with no
umbrella semantics. Adding a new suite (say `apps/otp/`) is one line in
the runner's deps list.

### Suite contract

Each suite at `apps/<name>/` exposes:

* A registry module listing benchmarks. The AWFY suite uses
  `Awfy.benchmarks/0` returning `[{:erlang | :elixir, module}, …]`.
* A behaviour for benchmark modules — for AWFY:
  `Awfy.Benchmark` (Elixir) and `awfy_benchmark` (Erlang) — requiring
  `inner_benchmark_loop/1` and `name/0`.
* `priv/` for benchmark inputs (e.g. `rap_benchmark.json`). Looked up
  via `code:priv_dir/1` so it works whether the suite is loaded by the
  runner via `mix compile` or by a target VM via `-pa`.

Future suites are expected to follow the same shape; the runner's
discovery mechanism currently knows about `Awfy` specifically but is
designed to grow into a registry-of-registries when a second suite
lands.

### Plain-Erlang target harness

`apps/awfy/src_target/awfy_target_runner.erl` is the only file in the
suite that's never compiled by the runner's `mix compile`. Its sole
purpose is to be compiled by each target OTP's `erlc` and loaded into
the target VM at measurement time. It exports two functions:

* `run_iters/3 (Module, InnerIter, IterCount) -> [ns]` — times each
  call to `Module:inner_benchmark_loop(InnerIter)` with
  `erlang:monotonic_time(nanosecond)` and returns the timings.
* `run_iters_io/3` — same, but emits one decimal integer per line on
  stdout and halts. Used when the host invokes the target via `-eval`.

Plain Erlang means no Elixir or library deps, so it compiles on every
OTP back to at least OTP 20. The host parses the integer-per-line
output into a `[ns]` list and feeds those to Benchee's statistics
calculator.

## Execution modes

`Awfy.BencheeRunner` picks one of three modes per measurement run,
based on the environment:

| Mode | Selector | Used when |
|---|---|---|
| **Target** | `AWFY_TARGET_ERL` env set | Target OTP differs from host OTP, or the orchestrator wants a clean cross-version comparison. |
| **In-process** | `AWFY_NO_ISOLATION=1` | Debugging; ExUnit tests where wrapping in a peer adds nothing. |
| **Isolated peer** | (default) | Same-OTP measurement; the historical default and still the simplest flow. |

### Isolated peer (default)

Each benchmark gets its own `:peer.start_link/1` BEAM, code path
inherited from the controller, communicating via stdio (no `epmd`,
no DNS). The closure handed to the peer is `Benchee.run/2` over the
benchmark's two scenarios (Erlang and Elixir), with its `:save` option
pointing at the run-dir's `.benchee` file. Costs ~300-500 ms per
benchmark in startup overhead, well below the per-bench time budgets
(4-10 s).

Documented in `ISOLATION_POLICY.md`. See `Awfy.PeerRunner` for the
peer mechanics.

### Target

When `AWFY_TARGET_ERL` is set, the runner stays on the host (modern
OTP + Elixir) and shells out to a different `erl` for each iteration
batch. Per scenario:

1. **Calibration**: 3 iterations to estimate per-iter cost.
2. **Sizing**: warmup count = ceil(`warmup` × 1e9 / median);
   measure count = ceil(`time` × 1e9 / median); always ≥ 3.
3. **Measurement**: one VM startup, one `awfy_target_runner:run_iters_io`
   call producing `(warmup + measure)` ns lines. Drop the first
   `warmup` count.
4. **Stats**: feed samples into a `%Benchee.Statistics{}` via
   `Benchee.Statistics.statistics/2` so the resulting
   `%Benchee.Suite{}` is byte-identical in shape to the regular path.

The output `.benchee` file is the same `:erlang.term_to_binary/1` of a
`Benchee.Suite` — `Awfy.Compare.Data` reads either path's output the
same way.

Elixir scenarios are silently skipped when their `.beam` file isn't
present in `AWFY_TARGET_BEAMS`. This is the expected state for OTP
< 24 where no compatible Elixir bundle ships; the Erlang scenarios
still run.

See `lib/awfy/target_runner.ex` for the full flow.

### When to use each

```
                   target OTP == host OTP?
                    ┌─── yes ──→ isolated peer (default)
                    │
host has Elixir ────┤
compatible with     │
the target OTP?     └─── no ───→ target  (set AWFY_TARGET_ERL)
                                   │
                                   └─── target Elixir compatible?
                                          yes → both langs measured
                                          no  → Erlang only (Elixir
                                                scenarios skipped)
```

## Build pipeline

### Host build (always modern)

`mix compile` at the root produces the runner's `.beam` files plus the
suite's path-dep `.beam`s. Runs on whatever OTP+Elixir the developer
or CI runner has installed. Dependencies (Benchee, Jason) are fetched
via Hex; the suite has none.

### Target build (per OTP under test)

Two entry points:

* **`bin/install-otp-source.sh <ref>`** — for macOS (and local
  Linux). Fetches the OTP source tarball at the given ref, applies
  `patches/OTP-<major>/*.patch` if any, runs `./configure && make &&
  make install` to a content-addressed prefix (`~/.local/otp/<sha>`).
  Then compiles the AWFY suite + target harness with the just-built
  `erlc`, dropping output at `<prefix>/awfy_target/awfy-0.1.0/{ebin,priv}`.
  Idempotent — exits early if the prefix already has a working `erl`.

* **`Dockerfile.linux`** — for the GHA Linux pipeline. Same flow in a
  multi-stage build: `otp-build` stage builds OTP from source, applies
  patches, compiles target beams to `/opt/awfy_target/awfy-0.1.0/`;
  `app` stage carries those over plus host Elixir (whichever ships
  `elixir-otp-<major>.zip` for that OTP), runs `mix deps.get` and
  `mix compile` to produce the runner's beams. Image base is
  `debian:bullseye-slim` so OpenSSL 1.1.1 is available — OTP < 23's
  crypto NIF uses APIs OpenSSL 3 removed.

Patches live under `patches/OTP-<major>/` as unified diffs against the
OTP source tree, applied with `patch -p1` in lexicographic filename
order. Both build paths share the same `patches/` directory. The
convention plus per-major notes (e.g. "OTP 20 needs HiPE for the
'jit' flavor — there's no BEAM JIT yet") live in
[`patches/README.md`](patches/README.md).

### Why bullseye, not bookworm

Debian Bookworm ships only OpenSSL 3, which OTP < 23's crypto NIF
won't compile against. We could carry per-major OpenSSL-3 compat
patches, but switching the base to Bullseye (OpenSSL 1.1.1) lets every
OTP from 20 to master share one toolchain. Bullseye Debian LTS
support runs through 2026-08; revisit then.

## A measurement, end to end

A single `mix awfy.measure` invocation:

1. **Resolve config**: read `--label`, `--out`, `--time`, `--warmup`,
   `--benchmarks`, etc. Defaults from `Awfy.BencheeRunner` —
   per-benchmark `:time` is calibrated from observed medians.

2. **Preflight** (unless `--ignore-preflight`): platform-specific
   stability checks — APFS encryption, CPU governor, thermal state.
   Warnings emitted; fatal only if the host is in a known-bad state
   (e.g. on AC with throttling). See `Awfy.Preflight.Parse`.

3. **Source verification**: every benchmark runs through
   `Awfy.verify/2` once before timing — checks `verify_result/1`
   passes for the configured `inner_iter`. A `verified: false` flag
   ends up in `meta.json` so the dashboard can grey out bad rows.

4. **Per-benchmark loop**: for each benchmark name, call
   `Awfy.BencheeRunner.run_one/3` which dispatches to one of the
   three execution modes above. The mode writes a `.benchee` file
   into the run-dir.

5. **Run-dir naming**: directory is
   `<timestamp>_otp<major>_elixir<version>_<short-sha>-<label>` (see
   `Awfy.Measure.Helpers`). The label suffix encodes the platform so
   parallel runs from different machines never collide on
   `gh-pages`.

6. **Metadata**: write `meta.json` with the full machine fingerprint
   (`arch`, `cpu`, `cores`, `os`), runtime info (`emu_flavor`,
   `schedulers_online`, `nif_version`), per-benchmark
   `inner_iter` and `source_sha256`, and overall config (`time`,
   `warmup`).

The output is a self-contained run-dir:

```
<run-dir>/
├── meta.json
├── Bounce.benchee
├── CD.benchee
├── DeltaBlue.benchee
└── …
```

## Source hashing

Each benchmark's source content is recorded as `source_sha256` in
`meta.json`. Two notes:

* **CRLF normalization**: `mix awfy.measure` strips `\r` from source
  bytes before hashing, so a Windows checkout produces the same
  hash as Linux/macOS. `.gitattributes` pins LF on `.ex` / `.erl`
  / `.exs` / `.hrl` as a defence-in-depth.
* **Source path resolution**: derived from
  `module_info(:compile)[:source]` for both Erlang and Elixir
  modules — lets benchmark suites live anywhere under
  `apps/<group>/{src,lib}/` without the runner needing to know.

## Dashboard pipeline

`mix awfy.compare --out site` reads every run-dir under `--out` (or
under `results/` if not specified), aggregates them into a single HTML
dashboard, and writes:

```
site/
├── index.html              # suite overview (geomean trend + snapshot)
└── per-bench/
    ├── Bounce.html
    ├── CD.html
    └── …                   # one per benchmark
```

The data layer (`Awfy.Compare.Data`) reads `meta.json` for run
metadata and decodes each `.benchee` file via `:erlang.binary_to_term/1`
to a `%Benchee.Suite{}`. Rows are flattened to one
`(run × benchmark × language)` tuple for the JS layer to filter.

The page (`Awfy.Compare`'s mix task) embeds the full dataset as JSON
inline plus vanilla Chart.js. Visual conventions:

* **Erlang.org skin**: brand red `#a2003e`, Montserrat sans, neutral
  panel `#f8f9fa`. Designed to look at home next to erlang.org docs.
* **Tabs by machine class**: linux-x86_64 / linux-arm64 / macos-arm64
  / windows-x86_64. Default tab is `linux-x86_64`. Series-grouping
  by class collapses ephemeral CI hostnames into stable trend lines.
* **Flavor radio**: jit / emu, default jit.
* **Headline**: "OTP X is N× faster than OTP Y on geomean of M
  benchmarks", per language, recomputed when filters change.
* **Latest snapshot**: horizontal bar chart, one row per benchmark,
  one bar per (OTP × lang) for the latest run on the selected
  platform. Whiskers show ± 2σ. Answers "which benches got faster
  on this OTP?" without scanning the time-series.
* **Error bars** on the per-benchmark line chart via
  `chartjs-chart-error-bars`.

The CI publish step does `git worktree add --orphan -b gh-pages site`
on first run, then merges new run-dirs and re-renders. Pages serves
from `gh-pages`. See `awfy.compare.ex` for the Elixir → HTML
pipeline and dashboard JS.

## CI workflows

Three workflows live in `.github/workflows/`:

### `bench-test.yml` — Phase 0 / GHA-hosted

Free GHA runners (linux-x86_64, linux-arm64, macos-arm64, windows-latest).
Numbers are noisy because the hardware is shared, but it validates the
pipeline (Dockerfile builds, installers work, mix tasks run, gh-pages
publish succeeds). Three triggers, three default scopes:

* **push** → master only (single ref, fast wiring check).
* **schedule** (Mondays 06:00 UTC) → `26,27,28,master`.
* **workflow_dispatch** → user-provided, default `26,27,28,master`.

Shorthand `26`, `27`, `28` (etc., now `20`-`29`) expand to the latest
matching `OTP-X.Y.Z` tag at resolve time.

The `resolve` job partitions targets into `targets_modern` (OTP ≥ 24,
existing Docker + same-OTP peer flow) and `targets_target_mode`
(OTP < 24, source-built target erl + cross-OTP shell-out). Each
partition feeds its own measure job (`measure-linux`, `measure-macos`,
`measure-windows` for modern; `measure-linux-target` for target-mode);
both feed the shared `publish` job.

### `bench.yml` — production

Terraform-managed ephemeral EC2 self-hosted runners for Linux
(x86_64 = `c6i.4xlarge`, arm64 = `c7g.4xlarge`) and Windows
(`c6i.4xlarge`); macOS-arm64 fed locally via `mix awfy.fill`. See
[`SETUP.md`](SETUP.md) § 2 for the operator-side AWS / GitHub-App
walkthrough and `terraform/main.tf` for the module config.
Cost ≈ $0.61/sweep; daily ≈ $220/year.

### `reuse.yml`

Runs `fsfe/reuse-action@v6` on every push to verify SPDX headers and
the project's REUSE compliance. The benchmark sources are MIT
(Stefan Marr); everything else is Apache-2.0.

## Adding things

### A new benchmark group

1. `mkdir apps/<name>/` with `src/`, `lib/`, `priv/`, `mix.exs`.
2. Project `app: :<name>`, `elixir: ~> 1.14`, no runtime deps.
3. Add benchmark sources (Erlang in `src/`, Elixir in `lib/<group>/`)
   and a `<Group>.benchmarks/0` registry function.
4. In the root `mix.exs`, append `{:<name>, path: "apps/<name>"}` to
   the deps list.
5. Add a section to the workflow's matrix if the new group has
   different inner-iteration defaults or extra setup needs.

A group that needs runtime infra (RabbitMQ broker, Phoenix Endpoint)
declares its own `setup/0` and `teardown/0` callbacks the runner
invokes on the peer. The current single-suite case doesn't exercise
this; the contract is preliminary.

### A new OTP target

1. Add the version (or shorthand) to the workflow input default and
   to `expand_ref` if it's a new major.
2. If the target OTP needs source patches, add them under
   `patches/OTP-<major>/` with a header comment naming the failure.
3. If the target needs a non-default Elixir version, update the
   `elixir_version_for_major` mapping in the workflow's `resolve`
   step.
4. Trigger a sweep. The matrix is `fail-fast: false`; failures
   surface per-target without breaking the others.

For OTP < 24, the target-runner path applies. `bench-test.yml`'s
`resolve` job splits the input refs into `targets_modern` (OTP ≥ 24,
the existing per-target Docker image + same-OTP peer flow) and
`targets_target_mode` (OTP < 24). The new `measure-linux-target`
job consumes the latter: it builds the target OTP from source via
`bin/install-otp-source.sh`, installs a pinned modern OTP/Elixir
host (`erlef/setup-beam`), and exports `AWFY_TARGET_ERL` /
`AWFY_TARGET_BEAMS` so `mix awfy.measure` shells out to the target
per benchmark.

For v1 the target-runner path is Linux-x86_64 + emu-flavor only.
Adding linux-arm64 and macos-arm64 is mechanical (the same script
runs on both) but each adds ~10 min of cold OTP build time, so we
widen as patches land. JIT-flavor coverage on OTP 20-23 needs HiPE
support (compile sources with `+native`); not wired through the
harness yet — see [`patches/README.md`](patches/README.md).

### A patch for an old OTP

See [`patches/README.md`](patches/README.md). The short version:
reproduce the failure on a clean checkout of the target ref, make the
smallest fix that compiles, drop the diff under
`patches/OTP-<major>/NN-short-name.patch` with a header explaining why
it's needed.

## Where the seams are

The system has a small number of explicit boundaries that make
extension and substitution local. Each is a place we expect future
change:

* **Suite registry**: `Awfy.benchmarks/0` (and per-group equivalents)
  lists what to run. Adding/removing benchmarks doesn't touch the
  runner.
* **Execution mode**: `Awfy.BencheeRunner` picks one of three modes
  via env var. Adding a fourth (e.g. remote-host SSH) means adding
  one branch and one new module like `Awfy.{X}Runner`.
* **Target harness**: `awfy_target_runner.erl` is plain Erlang and
  receives `(Module, InnerIter, IterCount)` over `erl -eval`. The
  protocol is "ns integers, one per line" — substitute any harness
  that emits that.
* **Dashboard renderer**: `Awfy.Compare` reads `.benchee` files
  (Benchee's term-binary format) plus `meta.json`. A new
  visualisation can read the same input without touching the
  measurement path.
* **CI runners**: `runs-on:` strings in the workflows are the only
  coupling to AWS / GHA. Swapping in another runner provider is a
  workflow edit.

## Related documents

* [`SETUP.md`](SETUP.md) — first-time setup of GHA permissions,
  the Terraform-managed AWS runner pools, GHCR visibility.
* [`ISOLATION_POLICY.md`](ISOLATION_POLICY.md) — why and how the peer
  isolation works.
* [`patches/README.md`](patches/README.md) — patch-file convention,
  per-OTP-major notes (HiPE for OTP 20-23, OpenSSL compat, etc.).
* [`LICENSING_POLICY.md`](LICENSING_POLICY.md) — Apache-2.0 vs MIT
  split, REUSE compliance.
* [`README.md`](README.md) — top-level "what this is, how to use it".
