<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# Cloud Bench Plan — daily AWFY sweeps across 4 (OS, arch) targets

A continuous-benchmarking setup that runs the AWFY suite against
OTP `master` (and tagged releases) on every relevant commit, across
the platforms that matter for performance regression detection:

- **macOS ARM64** — local M5 (self-hosted runner)
- **Linux x86_64** — AWS `c6i.4xlarge` with vCPU pinning
- **Linux ARM64** — AWS `c7g.4xlarge` (Graviton 3) with vCPU pinning
- **Windows x86_64** — AWS `c6i.4xlarge` + Windows with affinity pinning

Each leg uses a "right-sized big" instance (16 vCPU = 8 physical cores
× 2 threads on Intel; 16 single-thread cores on Graviton 3) and pins
the benchmark process to one physical core whose hyperthread sibling
is left idle. The unused cores absorb noise from background
housekeeping (kernel timers, monitoring agents, GC of unrelated
processes) instead of stealing cycles from the benchmark. See "CPU
pinning" below.

Each target runs both **JIT** and **emu** (`-emu_flavor emu`) so the
report covers the full performance matrix without a separate sweep.

## Goal

Catch JIT / compiler / runtime regressions on `master` within ~24h of
landing, with cost low enough to run unattended.

## Scope of relevant commits

Roughly **200 non-merge commits/year** on `master` touch paths whose
changes can move AWFY numbers (measured 2025-05 → 2026-05):

| Subsystem | Path | Commits/yr |
|-----------|------|------------|
| JIT | `erts/emulator/beam/jit`, `erts/emulator/asmjit` | 38 |
| Compiler | `lib/compiler/src` | 122 |
| Non-JIT emulator + sys (allocator, scheduler, BIFs, GC) | `erts/emulator/beam`, `erts/emulator/sys` | 163 |
| Preloaded + key stdlib | `erts/preloaded/src/{erlang,lists,erts_internal}.erl`, `lib/stdlib/src/{lists,maps,array}.erl` | 47 |

(Sums >200 because some commits touch multiple subsystems.) Realistically
only ~10-30% of those move benchmark numbers measurably; the rest are
bug fixes, refactors, and code paths AWFY doesn't exercise (no I/O, no
message passing, no OTP behaviours). Expect ~20-60 actually-perf-affecting
commits per year, of which a handful shift the suite by >2%.

## Architecture

```
                     ┌──────────────────────────┐
   master push ───►  │ GitHub Actions matrix    │
                     │                          │
                     │  build-linux-x86 (free)  │ ── docker push ───► GHCR
                     │  build-linux-arm (free)  │ ── docker push ───► GHCR
                     │                          │
                     │  measure-linux-x86       │ ── docker run on AWS c7i.large
                     │  measure-linux-arm       │ ── docker run on AWS c7g.large
                     │  measure-windows         │ ── installer on AWS c7i+Win
                     │                          │
                     │  publish (gh-pages)      │ ── push run-dirs + dashboard
                     └──────────────────────────┘
                                                   ▲
                                                   │ git push
                                                   │
                     ┌──────────────────────────┐  │
   user, on M5 ────► │ mix awfy.fill            │──┘
                     │  reads gh-pages, runs    │
                     │  missing macos-arm64     │
                     │  SHAs, commits locally   │
                     └──────────────────────────┘
```

**Build/measure split**:

- **Linux** — GHA builds a Docker image (free on public repos) using the
  prebuilt `otp_src_*.tar.gz` from upstream OTP CI. Only ERTS C/C++ +
  NIFs get rebuilt (~5-10 min). Image pushed to GHCR. AWS just pulls and
  runs `docker run … mix awfy.measure` — no build minutes on the paid
  clock.
- **Windows** — Each OTP commit produces an installer in upstream CI; the
  AWS Windows runner downloads, installs, and measures. No Docker
  (Windows containers are slow + expensive).
- **macOS ARM64** — Local-fill via `mix awfy.fill` on the M5. The cloud
  workflow doesn't depend on macOS to publish; the M5 picks up missing
  SHAs from gh-pages on the operator's schedule. See
  `FILL_TASK_PLAN.md`.
- **GHA hosted runners are NOT used for measurement in `bench.yml`** —
  too noisy (shared infrastructure, virtualised). They're fine for
  *building* the Docker image. The parallel `bench-test.yml` workflow
  uses them for end-to-end pipeline validation only — see Phase 0
  below.

## Cost per sweep

A "sweep" = one `(commit, platform, jit/emu)` matrix run = 8 measurements
across the cloud-driven legs (macOS lives in `mix awfy.fill`).

| Combo | AWS wall (boot + measure only) | Rate | Cost |
|-------|--------------------------------|------|------|
| Linux x86 (Docker pull + run) | ~13 min | $0.68/h (c6i.4xlarge) | $0.15 |
| Linux ARM (Docker pull + run) | ~13 min | $0.58/h (c7g.4xlarge) | $0.13 |
| Windows x86 (installer + measure) | ~20 min | $1.08/h (c6i.4xlarge + Win) | $0.36 |
| macOS ARM (M5, local fill) | n/a | $0 | $0 |
| | | **Total** | **~$0.65** |

**Annualised** (cron-only, weekly Monday sweep, no push triggers):

| Cadence | Linux x86 | Linux ARM | Windows | Total |
|---------|-----------|-----------|---------|-------|
| Weekly  | $30 | $26 | $20 | **~$76** |
| Daily   | $209 | $179 | $136 | **~$524** |
| Per-perf-relevant-commit (~200/yr) | $115 | $99 | $73 | **~$287** |

x86 Linux benchmark hours/year (weekly cron): 51 min/sweep × 52 ≈ 44 hr;
ARM matches x86; Windows is half (~18 hr/yr) since only one flavor.

If push-triggered runs are also enabled (~5/week), figures roughly
double — keeping pushes off the AWS clock is the cheapest knob to turn.

We deliberately **don't** go to full bare-metal (Equinix `m3.small.x86`,
`c7g.metal`, `c7i.metal-24xl + Win`); that tier costs ~$1,100/year for
daily and the variance improvement isn't worth ~14× the bill at the
detection thresholds we're aiming for (≥2% commit-over-commit deltas).
Pinned-on-shared-Nitro reaches ~3-5% CV in practice — sufficient for
the trends the dashboard is built around.

## Backfill and steady-state cadence

The dashboard is most useful when it shows the full historical arc, so
the first run after AWS comes online seeds history with one
measurement per **feature release** (`X.Y`) at its **latest patch**:
`OTP-20.0` → latest 20.0.x, `OTP-20.1` → latest 20.1.x, and so on.
About 4 feature releases per major × ~10 majors (20–28 plus master) ≈
**~40 sweeps to backfill**. At $0.65/sweep that's a one-time
**~$26** on the AWS side. The matrix already supports a comma-separated
`otp_refs` input on `workflow_dispatch`; the backfill is just a single
manual trigger with the resolved tag list.

**Release candidates count too.** Tagged RCs of an upcoming major
(`OTP-29.0-rc1`, `OTP-29.0-rc3`, …) belong in the backfill list so
the trend chart can show how the next major shaped up across its RC
window. They appear in the dataset as `29.0-rc1` etc. and bucket
under major "29", but the dashboard's "supported releases" default
ignores RC tags when picking the support window — major 29 stays
opt-in (via the snapshot major checkboxes) until `OTP-29.0` is
tagged GA. Master keeps its own dedicated bar/line labelled
`master`.

After backfill, the cron sweep stays on the latest patches of recent
feature releases (mostly to catch master-tip drift), and **each new
patch release** triggers a one-off measurement event to keep the
per-feature-release line current. Patch cadence across all live
majors is roughly 30-50 tags/year industry-wide → ~$20-30/year of
incremental AWS cost on top of the $76/yr cron baseline.

**Local-Mac implication.** `mix awfy.fill` on the M5 has to do the
same backfill work — ~40 sweeps × ~10 min each ≈ **~7 hours of M5
time**, comfortably done overnight in batches. After that the M5
mirrors the cloud cadence: pick up the latest patch tags as they
appear via the existing `mix awfy.fill` SHA-diff mechanism. See
`FILL_TASK_PLAN.md` for the operator workflow.

## Phase 0 — validate on GHA-hosted runners (no AWS, no M5)

Before wiring any AWS infrastructure or registering the M5, run the
full pipeline against **GitHub-hosted runners** for every leg. They're
free on public repos, available across all four platforms, and let
us verify pipeline correctness end-to-end without spending a dollar
or asking the user to start a self-hosted runner.

| Job | Runner label |
|-----|--------------|
| `build-linux` (already) | `ubuntu-latest`, `ubuntu-24.04-arm` |
| `measure-linux` | `ubuntu-latest`, `ubuntu-24.04-arm` |
| `measure-windows` | `windows-latest` |
| `measure-macos` | `macos-latest` (Apple Silicon — Phase-0 only, replaces local fill for the GHA dry run) |
| `publish` (already) | `ubuntu-latest` |

**What Phase 0 validates:**
- Dockerfile builds and the image runs.
- `install-otp-source.sh` works on GHA Linux runners.
- `install-otp-windows.ps1` resolves an installer URL and installs.
- `mix awfy.preflight`, `awfy.measure`, and `awfy.compare` all
  succeed end-to-end on each platform.
- `gh-pages` push happens, dashboard renders correctly.
- macOS `mix awfy.preflight` doesn't false-positive on the GHA
  runner (their environment is unusual — limited `pmset`, locked
  Spotlight state, etc.).

**What Phase 0 does NOT validate:**
- Stable timing data. GHA-hosted runners are shared, virtualised,
  and have ~5-10× higher CV than dedicated. Numbers are noisy
  enough that regression detection won't work — only pipeline
  correctness.
- AWS-specific behaviour (Terraform-managed runner Lambda
  quirks, IAM permissions, image pulls from GHCR onto the
  ephemeral EC2 instances, custom-AMI quiescence).
- M5-specific behaviour (the self-hosted runner registration, the
  drain script, OTP-from-source build on Apple Silicon).

**Implementation**: a parallel workflow `bench-test.yml` cloned
from `bench.yml` with all `runs-on:` labels swapped to GHA-hosted.
Triggered only on `workflow_dispatch`. Stays in the repo as a
permanent diagnostic — useful for reproducing CI bugs without
needing AWS access.

**Promotion to Phase 1**: once `bench-test.yml` runs cleanly across
all four platforms, the operator does the AWS / M5 setup
(`../SETUP.md`) and switches to `bench.yml` for daily runs. Costs and
stability characteristics from `CLOUD_BENCH_PLAN.md` apply from
that point on. `bench-test.yml` stays around for ad-hoc CI
debugging.

**Cost of Phase 0**: zero on public repos; on private repos it
consumes the included GHA minute allowance (2,000-3,000 min/month
per plan), which is plenty for a few validation runs.

## Why GHA builds the Docker image

1. **Wall clock** — Linux measurements drop from ~25 min to ~13 min on
   AWS (no build time on paid clock). Faster feedback.
2. **Layer caching** — GHA Docker layer cache means incremental rebuilds
   (typical commit: a few `.c` files) are 1-2 min, not 8. Cold builds
   happen rarely.
3. **Hermetic** — every run starts from an immutable image. No
   leftover asdf state, no path drift, no half-installed OTP.
4. **Parallelism** — both Linux arches build simultaneously on free GHA
   minutes while AWS cycles are unused.
5. **Free** — public-repo GHA minutes are unmetered; GHCR storage for
   public images is free.

Caveat to verify before publishing absolute numbers: Docker on Linux is
cgroups + namespaces (no virt layer), so overhead is typically <1%. Do
a one-time bake-off comparing a Docker run to a bare-metal install on
the same hardware and confirm the delta is in the noise. For *relative*
comparisons (commit-over-commit, version-over-version) it's fine
unconditionally.

## Wiring

### GHA workflow (`.github/workflows/bench.yml`)

Triggers:
- `push` to `master` (when paths in the perf-relevant subset above
  change — use `paths:` filter to skip doc-only commits).
- `workflow_dispatch` (manual).
- Daily `schedule` cron as a fallback (catches anything the path filter
  missed).

Matrix (cloud-driven legs only — macOS lives in `mix awfy.fill`):
```yaml
strategy:
  matrix:
    target:
      - { os: linux,   arch: x86_64, runner: [self-hosted, awfy-bench-linux-x86_64] }
      - { os: linux,   arch: arm64,  runner: [self-hosted, awfy-bench-linux-arm64]  }
      - { os: windows, arch: x86_64, runner: [self-hosted, awfy-bench-windows]      }
```

Build jobs (Linux only) push to
`ghcr.io/<org>/awfy-bench:<otp-sha>-<arch>`. Measure jobs take the
artifact, run `mix awfy.preflight && mix awfy.measure`, upload
`results/<run-dir>/` as a workflow artifact, then `publish` aggregates
them onto `gh-pages`. macOS results join the dashboard later, when the
operator runs `mix awfy.fill` and pushes.

### AWS runner provisioning

**Ephemeral self-hosted runners via Terraform** —
[`philips-labs/terraform-aws-github-runner`][module]. A Lambda
watches GitHub for `workflow_job` queued events, spins up a fresh
EC2 instance pinned to the right instance type, the runner
registers as one-shot, runs the job, the instance terminates.
Per-second EC2 billing — the bill tracks job wall-clock with
no idle window.

[module]: https://github.com/philips-labs/terraform-aws-github-runner

The pinning is the reason this path was picked over CodeBuild.
CodeBuild's on-demand fleet only exposes named compute classes
(`BUILD_GENERAL1_LARGE` etc.) — there's no way to require
`c6i.4xlarge` specifically without a Reserved Capacity Fleet
(always-on, ≥ $300/mo idle). AWFY's value proposition is trend
lines that hold up across years; "8 vCPUs of whatever CodeBuild
gave you today" doesn't satisfy that. Terraform-managed pools also
support ARM (`c7g.4xlarge`) cleanly, which CodeBuild's on-demand
fleet doesn't in every region.

Operator setup walkthrough: `../SETUP.md` § 2.
Module config + variables: `terraform/main.tf`,
`terraform/variables.tf`.

### macOS via local-fill (no self-hosted runner)

The M5 is the operator's daily-driver, not a CI box, so it is **not**
registered as a self-hosted GHA runner. macOS measurements are driven
locally by `mix awfy.fill`, which reads `gh-pages`, computes which
SHAs are missing for `macos-arm64`, and runs them on the operator's
schedule. See `FILL_TASK_PLAN.md` for the design and `../SETUP.md` § 3
for the operator workflow.

The preflight gate (`Awfy.Preflight.blocking_warnings/0`) protects each
local run from drifting into measurement under noisy conditions —
Spotlight indexing, Time Machine, low battery, etc.

## Open questions

1. **Where does the prebuilt `otp_src_*.tar.gz` come from?**
   Need to confirm upstream OTP master CI publishes it as a stable URL
   pattern. Fallback: build it ourselves in a separate GHA job that
   runs `./otp_build setup -a && tar` once per commit.

2. **Windows installer URL pattern.** Same — need a stable artifact URL
   per commit, or we build the installer ourselves in GHA on a
   `windows-latest` runner and upload it as the artifact.

3. **Result storage.** GHA artifacts (90-day retention) for short-term,
   S3 for long-term archive. The `mix awfy.compare` HTML output already
   handles arbitrary `results/` directories — we just need to point it
   at the bucket on a periodic basis (e.g. nightly rebuild of a public
   GitHub Pages site).

4. **What level of bare-metal do we need?** Resolved to **pinned
   c6i.4xlarge / c7g.4xlarge / c6i.4xlarge+Win** (see "CPU pinning"
   below) — gets us to ~3-5% CV at ~$76/yr (weekly cron) without
   needing dedicated hosts or metal instances. If detection
   sensitivity below 2% becomes a goal, revisit Equinix Metal
   `m3.small.x86` at $0.50/h.

5. **JIT/emu time tuning.** Current per-benchmark `:time` values in
   `BencheeRunner` are calibrated for JIT. The emu (interpreter) pass
   produces ~10× fewer samples in the same window — fine for slow
   benchmarks, may need 3-5× longer `:time` for fast ones (Bounce, List,
   Permute) to keep CV reasonable. Calibrate on first emu run.

## Sequence

1. ~~Author `Dockerfile.linux` for the build/measure split.~~
   Sanity-check that timings inside the container match a bare
   install (within ±1%): pending — requires a Linux x86 host (the
   M5 can build the image but can't time-validate it under QEMU).
   Will fall out of Phase 0 / first dedicated-runner sweep.
2. ~~Write the GHA workflow with the Linux-only Docker build first.~~
   (`bench.yml`; Phase-0 `bench-test.yml` for hosted-runner validation.)
3. ~~Wire AWS runner provisioning (Terraform-managed ephemeral
   self-hosted runners).~~ Workflow uses
   `runs-on: [self-hosted, awfy-bench-…]`; the Terraform module
   in `terraform/` provisions the pools, walked through in
   `../SETUP.md` § 2 (the user does this once).
4. ~~Add Windows installer fetch + measure.~~
   (`bin/install-otp-windows.ps1` + `measure-windows` job.)
5. ~~Register the M5 as a self-hosted runner.~~ Replaced by
   `mix awfy.fill` — see `FILL_TASK_PLAN.md`.
6. ~~Wire `mix awfy.compare` against the gh-pages archive; publish
   a Pages site.~~ (`bench.yml` → `publish` job.)
7. **Pending**: run Phase 0 (`bench-test.yml`) end-to-end on
   hosted runners, confirm the dashboard renders, then promote to
   `bench.yml` against AWS.
8. Tune emu-pass `:time` once enough samples are in.

## CPU pinning

The 4xlarge tier gives us 16 vCPUs in a way we can shape, not just 16
vCPUs. The benchmark runs single-threaded, so:

- **Linux** — `taskset -c 0 mix awfy.measure …` runs the controller
  (and through it the peer) on vCPU 0. On Intel (`c6i`), vCPUs 0 and 8
  are siblings on the same physical core; pinning to 0 and never
  scheduling on 8 keeps the core's L1/L2 free of contention. Graviton 3
  (`c7g`) has no SMT — one vCPU is one physical core, so pinning to 0
  is sufficient on its own.
- **Windows** — `Start-Process … -ProcessorAffinity 1` (PowerShell)
  pins to logical processor 0. Sibling-aware pinning matters here too:
  use `Get-CimInstance Win32_Processor` to confirm core/thread layout
  on the chosen instance type before locking the affinity mask.
- **Quiescence** — bring the rest of the box to a low-noise floor:
  disable `irqbalance` in the AWS Linux AMI's bake step, mount tmpfs
  for `/tmp`, and skip `fstrim` / scheduled scans on the bench window.
  Most of these are one-time AMI tweaks, documented under `../SETUP.md`.

The noise wins come from sibling-thread isolation, not from raw core
count — `c6i.large` would be cheaper, but then *every* vCPU has a
sibling owned by another tenant. The 4xlarge is paying ~5× the rate to
own its own siblings.

## Per-benchmark VM isolation

Every benchmark runs in a fresh BEAM peer node (`Awfy.PeerRunner`
behind `Awfy.BencheeRunner`) — see `../ISOLATION_POLICY.md`. Adds
~3 min wall clock to a full sweep across the matrix; on
per-second EC2 billing that's literal pennies.

## Why not …

- **GHA hosted runners for measurement** — shared infrastructure,
  virtualised, ~5-10× higher CV than dedicated. Fine for *building*,
  not for timing.
- **Build OTP on AWS** — wastes paid minutes on free GHA work. Only
  applies to Linux; Windows uses the upstream installer, macOS uses
  local-fill on the M5.
- **Renting a Mac in the cloud** (AWS `mac2-m2.metal`, Scaleway,
  MacStadium) — Apple licensing requires 24-hour minimum allocation
  everywhere, so a single sweep costs ~$22 vs $0 on the M5. Only worth
  considering if the M5 isn't available.
- **All-bare-metal from day 1** — adds ~10× cost for what's currently
  rounding error against engineer time. Switch when the noise floor
  data demands it.
