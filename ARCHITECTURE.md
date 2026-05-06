<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

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
│  • mix awfy.measure       │───▶│  Elixir.Awfy.TargetRunner.main   │
│  • mix awfy.compare       │    │  shipped as a target-Elixir      │
│  • Awfy.{BencheeRunner,   │    │  bundle, runs Benchee natively   │
│    PeerRunner,            │    └──────────────────────────────────┘
│    Runner}                │
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
├── apps/                   # Sibling apps — independently
│   │                       # compilable mix projects, low Elixir floor.
│   ├── awfy/               # AWFY suite (Stefan Marr's port)
│   │   ├── mix.exs
│   │   ├── src/            # Erlang benchmarks + helpers
│   │   ├── lib/awfy/       # Elixir benchmarks + behaviour + registry
│   │   └── priv/           # benchmark inputs (rap_benchmark.json)
│   │
│   └── awfy_target_runner/ # Target-side bundle (Phase 3 of
│       │                   #   PLAN/TARGET_ELIXIR_RUNNER_PLAN.md).
│       │                   # NOT a path-dep of the root project —
│       │                   # built standalone by
│       │                   # bin/build-target-bundle.sh, shipped to
│       │                   # the target OTP for cross-OTP measure.
│       ├── mix.exs
│       ├── lib/awfy/target_runner.ex   # Awfy.TargetRunner.main/0
│       └── deps/{benchee,deep_merge,statistex}/  # vendored Hex copies
│
├── lib/                    # Runner project (`:awfy_runner`)
│   ├── awfy/
│   │   ├── benchee_runner.ex   # picks execution mode, runs Benchee
│   │   ├── peer_runner.ex      # same-OTP `:peer` orchestration (default, OTP ≥ 24)
│   │   ├── runner.ex           # bundle-target shell-out (cross-OTP, OTP < 24)
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
│   ├── bench.yml           # push / schedule / dispatch with
│   │                       #   runner_pool=gha|aws (default gha)
│   ├── reuse.yml           # SPDX/REUSE compliance
│   └── shellcheck.yml      # bin/*.sh static analysis
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

### Target-side script: `apps/awfy_target_runner/`

The bundle path's "harness" is an Elixir script:
`Awfy.TargetRunner.main/0` in `apps/awfy_target_runner/`. Compiled
once per pinned target Elixir into a self-contained tarball
(`bin/build-target-bundle.sh`), shipped to the target host,
invoked via `erl -s 'Elixir.Awfy.TargetRunner' main`. The script
runs `Benchee.run/2` natively and writes a `.benchee` file the
host reads back through `binary_to_term/1`.

This is a **sibling app under `apps/`, not a path-dep of the root
project**. The root `mix compile` doesn't touch it; vendored
target-pinned deps with stripped dev/test trees never enter the
host `_build`. See `apps/awfy_target_runner/README.md` for the
vendoring policy and OTP × Elixir matrix.

The historical Phase-0/1/2 path used a plain-Erlang harness
(`awfy_target_runner.erl`) that returned raw timings the host
shaped into a Benchee suite. Phase 3 of
`PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` retired it — the bundle path
delivers Elixir benchmarks on every target OTP, removes the
~3.4 s/leg calibration tax, and collapses the modern/legacy split
in the workflow.

## Execution modes

`Awfy.BencheeRunner` picks one of three modes per measurement run,
based on the environment:

| Mode | Selector | Used when |
|---|---|---|
| **Bundle target** | `AWFY_TARGET_ERL` env set | Target OTP differs from host OTP. Always the path for OTP < 24. |
| **In-process** | `AWFY_NO_ISOLATION=1` | Debugging; ExUnit tests where wrapping in a peer adds nothing. |
| **Isolated peer** | (default) | Same-OTP measurement on OTP ≥ 24; the historical default and still the simplest flow. |

### Isolated peer (default, OTP ≥ 24)

Each benchmark gets its own `:peer.start_link/1` BEAM, code path
inherited from the controller, communicating via stdio (no `epmd`,
no DNS). The closure handed to the peer is `Benchee.run/2` over the
benchmark's two scenarios (Erlang and Elixir), with its `:save` option
pointing at the run-dir's `.benchee` file. Costs ~300-500 ms per
benchmark in startup overhead, well below the per-bench time budgets
(4-10 s).

Documented in `ISOLATION_POLICY.md`. See `Awfy.PeerRunner` for the
peer mechanics.

#### Why peer-runner stays on OTP ≥ 24 instead of unifying everyone on the bundle path

setup-beam's official Elixir bundles cover every OTP from 24 onward
out-of-the-box. Forcing modern measurements through the bundle path
would add a source-build of Elixir per OTP for no gain — peer
isolation already gives same-OS-process accuracy at zero extra
startup. The bundle path's wins (cross-OTP support, retiring the
Erlang harness) only matter where the modern path can't reach.

### Bundle target (OTP < 24, or any cross-OTP run)

`AWFY_TARGET_ERL` set → `Awfy.Runner.run/4` shells out to a
pre-built target bundle with `erl -noshell -pa <ebins> -s
'Elixir.Awfy.TargetRunner' main -extra <argv>`. The target's
`Awfy.TargetRunner` runs `Benchee.run/2` natively, saves a
`.benchee` file at the path argv specifies, and exits. The host
reads that file via `:erlang.binary_to_term/1` — same shape as the
peer flow's `.benchee`, no schema divergence.

Per scenario:

1. **Argv**: host marshals `[module, inner_iter, time_s, warmup_s,
   out_path]` into `-extra` (synonym `--`). Target reads via
   `:init.get_plain_arguments/0`. See `apps/awfy_target_runner/lib/awfy/target_runner.ex`
   moduledoc for the contract.
2. **Code path**: `-pa <bundle>/lib/*/ebin` plus `AWFY_TARGET_BEAMS`
   (the target-erlc-compiled benchmark modules from
   `Dockerfile.linux`'s build stage or `bin/install-otp-source.sh`'s
   target compile).
3. **Measurement**: Benchee on the target VM. Native run-time
   budgeting; no calibration pass to size warmup/measure counts.
4. **Save**: `Benchee.run` with `save: [path: out, tag: "target"]`
   writes `term_to_binary(%Benchee.Suite{})` directly.

Elixir scenarios run as long as `module.benchmark/1` is loadable on
the target VM; for OTP < 24 the pinned Elixir (1.9.4 / 1.11.4 /
1.13.4 / 1.14.5) is what gates compatibility. Erlang benchmarks
work on every supported OTP back to OTP 20.

#### Why the bundle uses an Elixir wrapper, not raw `erl -eval`

The host needs Benchee's statistics (median, percentile, std-dev)
on the target's timings. Either the host computes them from raw
samples (the Phase-0 Erlang harness's design — ~3.4 s/leg
overhead from the calibration pass it needed to size sample counts
under a hardcoded budget) or the target computes them. Letting
Benchee on the target do the math is simpler and more accurate:
Benchee already knows how to honour `:time` / `:warmup` budgets
without a separate calibration call. The bundle exists to ship
Benchee + Elixir + the runner script as one self-contained package
the host extracts and points at.

#### Why the bundle's vendored deps strip dev/test entries

Mix 1.9 walks the full transitive `deps()` tree of every dep
regardless of `MIX_ENV` and `only:` modifiers — it filters at
*build* time, not *resolution* time, and resolution-time SCM
lookup demands a working Hex registry. Target OTP for OTP < 24 is
built `--without-ssl` (OpenSSL 3 doesn't link against pre-23
crypto NIFs). No SSL → no Hex. So the vendored
`apps/awfy_target_runner/deps/{benchee,deep_merge,statistex}/`
copies have their `defp deps` bodies stripped of every dev/test/docs
entry, including the conditional `:table` branch in Benchee that's
unused on our path. `bin/refresh-target-deps.sh` automates the
re-strip on dep upgrades. See
`PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` Appendix A.

#### Why host Benchee is pinned to target Benchee compatibility

The `.benchee` file is `:erlang.term_to_binary/1` of a
`%Benchee.Suite{}` struct. Host reads it back with its own Benchee.
If the target's `Benchee.Suite` shape differs from the host's, the
struct fields don't line up and the host crashes at decode. We pin
both sides to Benchee 1.5; bumping the target version mandates a
matching host bump. Documented in `apps/awfy_target_runner/README.md`.

### When to use each

```
                   target OTP == host OTP?
                    ┌─── yes ──→ isolated peer (default)
                    │
                    └─── no ───→ bundle target  (set AWFY_TARGET_ERL +
                                                AWFY_TARGET_BUNDLE)
                                   │
                                   └─── target Elixir compatible
                                        with the suite?
                                          yes → both langs measured
                                          no  → Erlang only (Elixir
                                                benchmarks fail at
                                                load on the target,
                                                Awfy.Runner soft-skips)
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

### `bench.yml` — unified

One workflow, three triggers, two pools.

* **push** → smoke test, refs `21,28,master` (one per code path),
  `runner_pool` hard-pinned to `gha`. Pushes don't pay AWS bills.
* **schedule** (Mondays 06:00 UTC) → `fill` mode (rebuild whatever's
  missing on `gh-pages`), default `runner_pool=gha`. Flip the
  default to `aws` once the AWS pool is committed; one-line change.
* **workflow_dispatch** → user-provided `otp_refs` (default `fill`)
  and `runner_pool` (default `gha`). Operator entry point for
  backfills and AWS sweeps.

Shorthand `26`, `27`, `28` (etc., `20`–`29`) expand to the latest
matching `OTP-X.Y.Z` tag at resolve time. Special tokens `fill` and
`all` are handled by `bin/expand-otp-refs.sh` + `bin/resolve-fill-needs.sh`.

The `resolve` job emits six per-`(major, platform)` arrays
(`targets_modern_{linux,macos,windows}` for OTP ≥ 24,
`targets_legacy_{linux,macos,windows}` for OTP < 24) plus
`has_*` gates. Modern targets feed the same-OTP peer flow with a
per-target Docker image on Linux, setup-beam on Windows, source
build on macOS. Legacy targets feed the cross-OTP target-runner:
host orchestrator on a pinned modern Elixir/OTP shells out to a
target `erl` built from source via `bin/install-otp-source.sh`.

`runner_pool` only affects the measure-* jobs. Anything that
doesn't need bare-metal hardware accuracy (`resolve`, `build-linux`,
`publish`) stays on free GHA-hosted Linux regardless of the pool.
CPU pinning (`--cpuset-cpus=0` on Linux Docker, `taskset -c 0` on
target-mode Linux, `ProcessorAffinity = 1` on Windows) only fires
when `runner_pool=aws` — pinning is meaningless on shared GHA
tenancy. The Windows `wmic` shim only runs on GHA windows-latest;
the AWS Windows AMI is pinned to a version that still ships WMIC.

The AWS pool is Terraform-managed ephemeral EC2 (Linux
x86_64 = `c6i.4xlarge`, arm64 = `c7g.4xlarge`, Windows
= `c6i.4xlarge`); macOS-arm64 is always GHA-hosted (operator's M5
covers local-fill via `mix awfy.fill` — no AWS macOS pool in
scope). See [`SETUP.md`](SETUP.md) § 2 for the operator-side
walkthrough and `terraform/main.tf` for the module config.
Cost ≈ $0.61/sweep on `aws`; daily ≈ $220/year if the schedule
default flips. `gha` pool is free.

### `reuse.yml`

Runs `fsfe/reuse-action@v6` on every push to verify SPDX headers and
the project's REUSE compliance. The benchmark sources are MIT
(Stefan Marr); everything else is Apache-2.0.

### `shellcheck.yml`

Static analysis for `bin/*.sh` on every push. Same checks `mix
precommit` runs locally.

## Bundle distribution — Phase 2 of `TARGET_ELIXIR_RUNNER_PLAN`

For the legacy (pre-OTP-24) measurement path, the workflow ships a
self-contained target-Elixir bundle in addition to the target OTP
build:

```
prep-target-bundle (GHA-hosted ubuntu-latest, runs once per Elixir
                    pin per OTP major in the run)
        │
        ├── pulls per-OTP-SHA image from build-linux-target (GHCR)
        ├── docker create + docker cp /opt/otp → host fs
        ├── bin/build-target-bundle.sh <otp-prefix> <elixir-version>
        │       └── builds Elixir from source against that OTP,
        │           mix-compiles vendored Benchee + the runner module,
        │           tars bin/ + lib/elixir/ebin + lib/<sub>/ebin
        │           into target_bundle_<elixir-version>.tar.gz
        ├── actions/upload-artifact (always)
        └── aws s3 cp target_bundle_*.tar.gz \
                       s3://AWFY_TARGET_BUNDLE_S3_BUCKET/...   (only
                                                                when
                                                                runner_pool=aws)
                                                                ↓
measure-{linux,windows,macos}-target-v2
        │
        ├── docker pull / install target OTP (existing path)
        ├── actions/download-artifact target-bundle-<elixir-version>
        ├── tar xzf … → ./bundle/{bin,lib/...}
        ├── exports AWFY_TARGET_ERL / AWFY_TARGET_BUNDLE / AWFY_TARGET_BEAMS
        └── mix awfy.measure --runner=bundle …
                            (BencheeRunner dispatches to Awfy.Runner,
                             which shells out to the bundle's pre-
                             compiled Awfy.TargetRunner via erl -s)
```

One Linux Docker image, two consumption modes:

* **GHA**: `docker run` for measurement (hermetic userspace inside
  the container — same as today's modern path).
* **AWS**: `docker create` + `docker cp /opt/otp` + bare-metal
  `./otp/bin/erl` execution (no container around the benchmark, so
  no cgroup/namespace overhead in the timed window).

The `-target-v2` jobs run **in parallel** with the legacy
`-target` jobs in Phase 2; `bin/compare-target-paths.sh` validates
parity (geomean ±5%, no individual benchmark drift > 15%) before
Phase 3 deletes the legacy path.

The bundle is built on GHA-hosted Linux and consumed on every
target platform — Windows and macOS too. Works because Elixir BEAM
bytecode is platform-independent, the vendored deps
(Benchee/deep_merge/statistex) are pure Elixir, and the
platform-dependent NIFs come from the per-platform target OTP
install supplied separately. Phase 2 acceptance includes
cross-platform parity.

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

For OTP < 24, the bundle target path applies. The `bench.yml`
`resolve` job emits per-platform `targets_legacy_*` arrays
(OTP < 24, bundle-target mode) alongside the `targets_modern_*`
arrays (OTP ≥ 24, same-OTP peer flow). The
`measure-{linux,macos,windows}-target` jobs consume the legacy
arrays: they acquire the target OTP (Linux: `docker pull` +
`bin/extract-otp-from-image.sh`; macOS: `bin/install-otp-source.sh`;
Windows: `install-otp-windows.ps1` against the function release),
download the matching `target-bundle-<elixir-version>` artifact
from `prep-target-bundle`, install a pinned modern OTP/Elixir host
(`erlef/setup-beam`), export `AWFY_TARGET_ERL` /
`AWFY_TARGET_BUNDLE` / `AWFY_TARGET_BEAMS`, and call
`mix awfy.measure` — `Awfy.BencheeRunner` automatically dispatches
to `Awfy.Runner` (the bundle path) when `AWFY_TARGET_ERL` is set.

Bundle-target coverage: Linux x86_64 + arm64, Windows x86_64,
macOS arm64. Erlang benchmarks always run; Elixir benchmarks run
when the pinned target Elixir (1.9.4 / 1.11.4 / 1.13.4 / 1.14.5
for OTP 20-23 respectively) loads the benchmark module. JIT-flavor
coverage on OTP 20-23 needs HiPE support (compile sources with
`+native`); not wired through the harness yet — see
[`patches/README.md`](patches/README.md).

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
* **Target harness**: `apps/awfy_target_runner/lib/awfy/target_runner.ex`
  is the bundle-side script. It accepts argv `(module, inner_iter,
  time_s, warmup_s, out_path)` via `erl -extra`, runs Benchee, and
  writes the suite as `term_to_binary` to `out_path`. Substitute
  any harness that follows the same I/O contract.
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
