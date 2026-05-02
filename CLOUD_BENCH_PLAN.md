# Cloud Bench Plan — daily AWFY sweeps across 4 (OS, arch) targets

A continuous-benchmarking setup that runs the AWFY suite against
OTP `master` (and tagged releases) on every relevant commit, across
the platforms that matter for performance regression detection:

- **macOS ARM64** — local M5 (self-hosted runner)
- **Linux x86_64** — AWS `c7i.large` (or bare-metal Equinix Metal)
- **Linux ARM64** — AWS `c7g.large` (Graviton 3)
- **Windows x86_64** — AWS `c7i.large` + Windows

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
                     │  measure-macos           │ ── self-hosted on M5
                     │                          │
                     │  collect-results         │ ── upload to S3 / artifact
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
- **macOS ARM64** — Self-hosted GHA runner on the M5, labeled
  `macos-m5`. Build via standard `./configure && make` (~8 min on M5).
- **GHA hosted runners are NOT used for measurement** — too noisy
  (shared infrastructure, virtualised). They're fine for *building* the
  Docker image, just not for timing.

## Cost per sweep

A "sweep" = one `(commit, platform, jit/emu)` matrix run = 8 measurements.

| Combo | AWS wall (boot + measure only) | Rate | Cost |
|-------|--------------------------------|------|------|
| Linux x86 (Docker pull + run) | ~13 min | $0.09/h | $0.02 |
| Linux ARM (Docker pull + run) | ~13 min | $0.07/h | $0.02 |
| Windows x86 (installer + measure) | ~20 min | $0.18/h | $0.06 |
| macOS ARM (M5, self-hosted) | n/a | $0 | $0 |
| | | **Total** | **~$0.10** |

**Annualised**:

- Daily sweep: ~**$36/year**
- Per-perf-relevant-commit sweep (~200/yr): ~**$20/year**

For publication-quality numbers (bare-metal everywhere — Equinix Metal
`m3.small.x86` for Linux x86 at $0.50/h, AWS `c7g.metal` for Linux ARM at
$2.50/h, AWS `c7i.metal-24xl + Win` for Windows at ~$5.40/h): adds ~$3
to a sweep, so ~**$1,100/year** for daily. Still trivial against
engineer time.

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

Matrix:
```yaml
strategy:
  matrix:
    target:
      - { os: linux,   arch: x86_64, runner: ubuntu-latest }
      - { os: linux,   arch: arm64,  runner: ubuntu-24.04-arm }
      - { os: windows, arch: x86_64, runner: windows-latest }   # build only
      - { os: macos,   arch: arm64,  runner: [self-hosted, macos-m5] }
```

Build jobs (Linux only) push to
`ghcr.io/<org>/awfy-bench:<otp-sha>-<arch>`. Measure jobs (all four)
take the artifact, run `mix awfy.preflight && mix awfy.measure`, upload
`results/<run-dir>/` to S3 + as a workflow artifact.

### AWS runner provisioning

Two options — pick one to start, switch later if needed:

**A. Ephemeral self-hosted runners via Terraform** (preferred long-term)
- Each measure job triggers a Terraform apply that spins up an EC2
  instance, registers it as a self-hosted runner, then runs the job and
  tears down.
- Best cost: instance only billed for the ~13-20 min the job runs.
- Higher setup complexity.

**B. AWS CodeBuild as a self-hosted runner** (simpler bootstrap)
- AWS-managed runner pool; pay per-build-minute, no instance
  lifecycle to manage.
- Slightly more expensive per minute but zero ops.

Start with B for time-to-first-measurement, migrate to A if the daily
cost outgrows it.

### Self-hosted M5 runner

`actions-runner` daemon installed on the M5 with label `macos-m5`. The
preflight gate (`mix awfy.measure` already calls
`Awfy.Preflight.blocking_warnings/0`) refuses to start if the M5 is
under load — i.e. the user is in the middle of a build. Job retries
automatically the next time the runner is idle.

For dedicated benchmark windows: optionally a launchd job that disables
Spotlight + Time Machine + nightly cron during a scheduled window.
Out of scope for v1.

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

4. **What level of bare-metal do we need?** Start with shared-tenant
   (`c7i.large` / `c7g.large`) and watch the noise floor via the
   existing stability scripts. If CV is consistently above ~3% even
   with the preflight gate clean, switch to Equinix Metal `m3.small.x86`
   at $0.50/h.

5. **JIT/emu time tuning.** Current per-benchmark `:time` values in
   `BencheeRunner` are calibrated for JIT. The emu (interpreter) pass
   produces ~10× fewer samples in the same window — fine for slow
   benchmarks, may need 3-5× longer `:time` for fast ones (Bounce, List,
   Permute) to keep CV reasonable. Calibrate on first emu run.

## Sequence

1. Spike: build the Docker image locally, run a measure inside it on
   this Mac, sanity-check that timings match a bare install (within ±1%).
2. Write the GHA workflow with the Linux-only Docker build first; have
   the measure job run on `ubuntu-latest` (free, but noisy) to validate
   the full pipeline end-to-end.
3. Wire AWS runner provisioning (option B — CodeBuild-as-runner).
4. Add Windows installer fetch + measure.
5. Register the M5 as a self-hosted runner.
6. Wire `mix awfy.compare` against the S3 archive; publish a Pages site.
7. Tune emu-pass `:time` once enough samples are in.

## Per-benchmark VM isolation

Every benchmark runs in a fresh BEAM peer node — see
`ISOLATION_POLICY.md`. Adds ~3 min wall clock to a full sweep
across the matrix; cost falls within CodeBuild per-minute
rounding. Land before the network and extended plans start adding
benchmarks.

## Why not …

- **GHA hosted runners for measurement** — shared infrastructure,
  virtualised, ~5-10× higher CV than dedicated. Fine for *building*,
  not for timing.
- **Build OTP on AWS** — wastes paid minutes on free GHA work. Only
  applies to Linux; Windows uses the upstream installer, macOS uses M5.
- **Renting a Mac in the cloud** (AWS `mac2-m2.metal`, Scaleway,
  MacStadium) — Apple licensing requires 24-hour minimum allocation
  everywhere, so a single sweep costs ~$22 vs $0 on the M5. Only worth
  considering if the M5 isn't available.
- **All-bare-metal from day 1** — adds ~10× cost for what's currently
  rounding error against engineer time. Switch when the noise floor
  data demands it.
