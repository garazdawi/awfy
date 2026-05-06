<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# AWFY Target-Elixir Runner Plan

Replace the Erlang-only target-runner harness used for pre-OTP-24 measurements with a full target-Elixir bundle. Keep the modern peer-runner path untouched. Net effect: Elixir benchmarks become measurable on every OTP we support, the Erlang harness goes away, and the modern/legacy split in the workflow shrinks from "two parallel sets of measure jobs" to "one set with a richer install step on the legacy branch".

Quick context: see [`../ARCHITECTURE.md`](../ARCHITECTURE.md) for the current peer/target dispatch and [`../ISOLATION_POLICY.md`](../ISOLATION_POLICY.md) for why per-benchmark VM isolation matters.

## Goals

1. **Delete the Erlang-only target harness.** `apps/awfy/src_target/awfy_target_runner.erl`, `lib/awfy/target_runner.ex`, and the calibration tax we measured (~50s/leg) all go away.
2. **Run Elixir benchmarks on pre-24 OTPs.** Today they're silently skipped on the legacy path. Best-effort: any benchmark that happens to compile under the pinned Elixir for that target gets measured.
3. **No regression on the modern path.** Setup-beam-driven peer-runner stays. Measure jobs for OTP ≥ 24 are unchanged.
4. **Single result format.** Target-side writes a `.benchee` file directly; host's compare flow reads it without knowing whether it came from peer or target.
5. **Document the *why*, not just the *what*.** Every design choice in this plan exists for a specific reason — version-pinning, dep stripping, Docker-image-with-two-consumers, Ubuntu-on-AWS, bundle-on-GHA, etc. `ARCHITECTURE.md` should leave a future reader (or future-us six months from now) able to answer "why is it like this?" without spelunking commit history. Each phase's documentation deliverable spells out which rationales need to land where.

Non-goals:
- Eliminating PeerRunner (216 LOC). Modern path keeps using it; we discussed and rejected forcing source-build Elixir for OTP ≥ 24.
- Changing how OTP is built per-platform. Target OTP source-build pipeline is unchanged.

In scope as a parallel concern:
- **Merging `bench.yml` and `bench-test.yml` into one parameterised workflow** with a `runner_pool` input (`gha` | `aws`, default `gha`). Same prep-target-bundle step; measure jobs route to GHA-hosted or AWS self-hosted runners based on the input. Lets us land the AWS runner pool incrementally — flip the default later, no further workflow surgery — and means the target-Elixir work below has exactly one place to land.

## Architecture

```
host (modern, fixed Elixir/OTP)
    Mix.Tasks.Awfy.Measure
        │
        ├─ OTP ≥ 24 → BencheeRunner.run_isolated → PeerRunner       (unchanged)
        │
        └─ OTP < 24 → BencheeRunner.run_target  → Awfy.Runner       (NEW path)
                                                      │
                                                      └─ System.cmd($TARGET/bin/erl,
                                                            -pa $BUNDLE/lib/*/ebin
                                                            -s 'Elixir.Awfy.TargetRunner' main
                                                            -- <module> <inner_iter> <time> <warmup> <out>)

target side (per OTP major × Elixir version)
    target_bundle_<elixir_version>.tar.gz  (built once on GHA-hosted ubuntu-latest)
        bin/{elixir,iex,mix}, bin/*.bat
        lib/elixir/ebin/*.beam            ← Elixir 1.9.4 / 1.11.4 / 1.13.4 / 1.14.5
        lib/{benchee,deep_merge,statistex}/ebin/*.beam
        lib/awfy_target_runner/ebin/Elixir.Awfy.TargetRunner.beam   ← pre-compiled run-script

OTP × Elixir matrix:
    OTP 20 → Elixir 1.9.4
    OTP 21 → Elixir 1.11.4
    OTP 22 → Elixir 1.13.4
    OTP 23 → Elixir 1.14.5
```

## Workflow consolidation

Today there are two near-identical workflows: `bench.yml` (the production cloud workflow) and `bench-test.yml` (the smoke-test variant). Both have the same resolve→build→measure→publish skeleton; they diverge mostly in which refs they run and which runner labels they target. Folding them into one parameterised workflow gives the target-Elixir work a single landing point and gives the AWS migration a clean toggle.

Shape:

```yaml
name: bench
on:
  push:                       # smoke test (1 ref, GHA)
  schedule:                   # nightly (full backfill, GHA today, AWS later)
  workflow_dispatch:
    inputs:
      runner_pool:
        type: choice
        options: [gha, aws]
        default: gha
      refs:
        type: string
        default: smoke
      ...

jobs:
  resolve: ...
  prep-target-bundle: ...    # always GHA-hosted ubuntu-latest, output cached/uploaded

  measure-linux:
    runs-on: ${{ inputs.runner_pool == 'aws' && fromJSON('["self-hosted","aws","linux"]') || 'ubuntu-latest' }}
    needs: [resolve, prep-target-bundle]
    ...

  measure-linux-target:        # pre-24, uses the new bundle
    runs-on: ${{ inputs.runner_pool == 'aws' && fromJSON('["self-hosted","aws","linux"]') || 'ubuntu-latest' }}
    needs: [resolve, prep-target-bundle]
    ...

  measure-{macos,windows,*-target}: <same pattern>

  publish: ...                 # always GHA-hosted (no benchmark accuracy needed)
```

Bundle distribution adapts to the runner pool:
- `runner_pool=gha`: `actions/upload-artifact` from prep, `actions/download-artifact` in measure jobs.
- `runner_pool=aws`: prep job additionally runs `aws s3 cp target_bundle.tar.gz s3://awfy-target-bundles/...`; AWS measure jobs `aws s3 cp` to fetch. The S3 step is conditional, so flipping the pool input is the only switch.

Principle for runner placement: **any job that doesn't need bare-metal hardware accuracy stays on GHA-hosted ubuntu-latest, regardless of `runner_pool`.** That's `resolve`, `prep-target-bundle`, `build-linux` (the Docker image builder for *every* Linux measure path — modern and legacy after Phase 2), and `publish`. Pinning AWS to *only* the measure jobs keeps the AWS bill confined to the work that actually requires bare-metal — hours of OTP source builds and Docker image creation stay free on GHA's unlimited public-repo Actions minutes. AWS measure-linux jobs (modern and legacy) just `docker pull` from GHCR.

Push-triggered smoke runs always pin `runner_pool=gha` (we don't want every push paying AWS bills). Nightly cron stays `gha` initially; flipping to `aws` is a one-line default change once the AWS runner pool is online and we've decided to commit.

Rationale:
- One workflow file means one place to change the resolve step, the prep step, the publish step, every measure job's install logic.
- The `runner_pool` input is orthogonal to everything else, so adding it doesn't constrain the target-Elixir runner work below — they compose.
- Defers any commitment to AWS until the runner pool is provisioned. The merged workflow runs identically to today's `bench.yml`/`bench-test.yml` while `runner_pool` defaults to `gha`.

This consolidation is **Phase 0** below — additive, deletes nothing, gives Phases 1–3 a single workflow file to edit.

### AWS runner pool specifics

When `runner_pool=aws`, the self-hosted runners run **Ubuntu LTS** (initially 22.04 or 24.04 as decided at provisioning time, Terraform-pinned to a specific AMI).

Why Ubuntu rather than Amazon Linux:

- The current `Dockerfile.linux` base is `debian:bullseye-slim`. Ubuntu LTS shares glibc and OpenSSL 1.1 with bullseye, so the OTP binary built today runs on the AWS host unchanged — no Dockerfile rewrite, no `apt → dnf` swap, no hand-rolled OpenSSL 1.1 for pre-23 OTP.
- GHA-hosted runners are also Ubuntu. Matching the AWS AMI to that means the only difference between `runner_pool=gha` and `runner_pool=aws` measurements is the hardware. Switching to Amazon Linux would introduce a kernel-tuning / userspace divergence that confounds the GHA→AWS handoff.
- AWS supports Ubuntu as a first-class AMI (Canonical-published, no extra cost vs Amazon Linux). LTS support is 5+5 years, predictable.

Bare-metal execution (no container overhead during measurement) on AWS:

- The Linux measure jobs `docker pull` the per-OTP image (built by `build-linux` on GHA, pushed to GHCR) — same as today's GHA flow.
- On AWS, the job extracts the OTP install dir out of the image (`docker create` + `docker cp /opt/otp ./otp/`, then `docker rm`) and runs `./otp/bin/erl` directly on the host. No `docker run`, no container around the benchmark.
- On GHA, the same image is used via `docker run` (no extraction). That's the unchanged Linux flow we have today.
- The `Dockerfile.linux` final stage keeps producing an `/opt/otp` install layout; both flows consume that without further changes. A small `bin/extract-otp-from-image.sh` helper does the AWS-side extract.

The pre-23 OpenSSL 1.1 question remains the same as today: bullseye and Ubuntu LTS both ship 1.1.1, so the existing `--without-ssl` policy in `install-otp-source.sh` (which is moot for Linux after Phase 2's build-linux extension) carries over unchanged for any platform that still source-builds OTP.

## Phases

Each phase is independently mergeable and reversible. Phase boundaries are the natural rollback points.

### Phase 0 — workflow consolidation (additive, no behaviour change)

**Deliverables:**
- Merge `bench.yml` and `bench-test.yml` into a single `bench.yml` driven by event triggers (`push`, `schedule`, `workflow_dispatch`) and the `runner_pool` / `refs` inputs.
- Add the `runner_pool` input (`gha`/`aws`, default `gha`) and a small `pick-runner-label` reusable step that returns the right `runs-on` JSON for each platform.
- Existing `bench-test.yml` deleted; its push-event behaviour folded into the merged file under a `if: github.event_name == 'push'` guard.
- **Documentation:** update `SETUP.md` and `ARCHITECTURE.md` so the workflow section describes one workflow with `runner_pool` rather than two. Update any `README.md` mentions of `bench-test.yml`.

**Tests:**
- Push-event smoke run on the merged workflow produces the same publish output as today's `bench-test.yml`.
- A `workflow_dispatch` with `runner_pool=gha` and `refs=all` produces the same matrix and outputs as today's `bench.yml`.
- A `workflow_dispatch` with `runner_pool=aws` runs (assuming a stub AWS runner labelled `self-hosted aws linux` is registered) and reaches the install-OTP step before any AWS-specific failure. Confirms the routing works end-to-end before AWS is fully wired.

**Acceptance:** the merged workflow's GHA-default behaviour is byte-for-byte equivalent to the current two workflows on push and on `all` dispatch. AWS routing is reachable but not exercised.

### Phase 1 — `apps/awfy_target_runner/` sub-project (additive, no behaviour change)

**Documentation deliverables (alongside the code deliverables below):**
- New `apps/awfy_target_runner/README.md` covering the sub-project's purpose, the vendoring policy (why dev/test deps are stripped, when to refresh via `bin/refresh-target-deps.sh`), and the OTP × Elixir version matrix.
- `SETUP.md` gains a section on building target Elixir locally (for running pre-24 measurements on a workstation).

**Deliverables:**
- New umbrella sub-app at `apps/awfy_target_runner/` with its own `mix.exs` and one Elixir module: `Awfy.TargetRunner` (the `main/1` script with arg parsing and `Benchee.run/2` invocation).
- Vendored deps under `apps/awfy_target_runner/deps/{benchee,deep_merge,statistex}/` with `mix.exs` files stripped of dev/test deps. The strip is a one-time edit; subsequent dep upgrades go through a small `bin/refresh-target-deps.sh` script that re-fetches and re-strips.
- `bin/build-target-bundle.sh <otp_major> <elixir_version>`. Idempotent: builds OTP from source (if not cached) → builds Elixir against it → mix-compiles vendored deps → mix-compiles the runner module → tars `bin/`, `lib/elixir/ebin`, `_build/prod/lib/*` into `target_bundle.tar.gz`.
- `bin/install-elixir-source.sh <elixir_version> <otp_prefix>`. Clones the elixir tag, makes against the target OTP, no install.

**Tests:**
- Unit tests for the runner module's argv parsing and `.benchee` output shape.
- Local smoke test: build OTP-20.3 and the bundle, run the runner against a one-line benchmark, verify the produced `.benchee` is readable by `Awfy.Compare.Data` on the host.

**Acceptance:** `bin/build-target-bundle.sh 20 1.9.4` produces a bundle whose runner can be invoked end-to-end on the local Mac, output loaded by `Awfy.Compare.Data.load/1` without errors. Nothing in the existing measure path changes; nothing in CI runs the new code yet.

### Phase 2 — `Awfy.Runner` and `prep-target-bundle` workflow (parallel install, no replacement yet)

**Deliverables:**
- New `lib/awfy/runner.ex` (~80 LOC). Single function: `run(target_dir, module, inner_iter, opts)` shells out to the target Elixir bundle, blocks, returns the `.benchee` path. Replaces `Awfy.TargetRunner` in spirit but doesn't yet activate.
- `prep-target-bundle` workflow job (matrix over four OTP/Elixir pairs) on `ubuntu-latest`. Uses `actions/cache` keyed by `(elixir_version, otp_major, mix.lock_hash, patches/OTP-MAJOR.MINOR/_hash)`. Outputs the bundle as a workflow artifact.
- **Extend `build-linux` to cover pre-24 OTPs.** `Dockerfile.linux` is already parametric on `OTP_SHA` (header comment explicitly says "OTP 20 → master with the same toolchain"); only the matrix needs to grow to include the legacy SHAs × `[x86_64, arm64]`. Output: per-OTP-SHA Docker image pushed to GHCR, just like the modern path. Same image-build mechanics, same caching, same hermetic-userspace guarantee.
- New parallel measure jobs: `measure-{linux,windows,macos}-target-v2`. Same matrix as the existing `-target` jobs.
  - `measure-linux-target-v2`: `docker pull` the per-OTP-SHA image (from the extended `build-linux`), `docker run` with the bundle artifact mounted in. No source build at job time.
  - `measure-{windows,macos}-target-v2`: install target OTP at job time (no Docker), download the bundle artifact, extract over the OTP install.
  - All three call `mix awfy.measure` with a new flag that selects `Awfy.Runner` instead of `Awfy.TargetRunner`.

**Tests:**
- One CI run with the `-target-v2` jobs alongside the existing `-target` jobs. Both produce `.benchee` files for the same OTP refs. Compare medians: should agree within ~5% (peer/target/Elixir-runner all measure the same code).
- Verify the extended `build-linux` matrix produces working images for all pre-24 SHAs × x86_64/arm64. Check that the resulting image size is comparable to the modern Linux images (no regressions from any pre-24 build artifacts leaking into the layer).
- Bare-metal execution check: confirm `bin/extract-otp-from-image.sh` round-trips an OTP install onto an Ubuntu host and `./otp/bin/erl` reports the expected OTP release. (Initially ran in a stub Ubuntu runner; replays on the real AWS pool when it's online.)

**Documentation deliverables:**
- `ARCHITECTURE.md`: describe the new bundle distribution (one Linux Docker image source, two consumption modes — `docker run` on GHA, extract + bare-metal on AWS) and the prep-target-bundle role.
- `SETUP.md`: add the AWS Ubuntu pool prerequisites (Terraform AMI pin, runner labels, S3 bucket for bundles).
- `terraform/README.md`: AMI selection (Ubuntu LTS, version-pinned), runner-pool labels.

**Acceptance:** parity dashboard run for one full pre-24 backfill. `-target-v2` jobs all green. Median deltas within tolerance. No effect on the production publish path — `-target-v2` results land in a side directory that the dashboard ignores.

### Phase 3 — flip the dispatch, delete the old path

**Deliverables:**
- `Awfy.BencheeRunner.run_one_benchmark/2` switches its target branch from `Awfy.TargetRunner.run_benchmark` to `Awfy.Runner.run`. The env-var toggle from Phase 2 goes away.
- Workflow: rename `measure-*-target-v2` to `measure-*-target`, delete the old `-target` jobs. `prep-target-bundle` becomes a hard dependency. The extended `build-linux` matrix from Phase 2 is now the only Linux OTP-build path (modern + legacy unified through one job).
- `resolve-fill-needs.sh`: drop the modern/legacy split in matrix output. Single `targets_*` array per platform, `(otp_ref, elixir_version)` tuple per entry.
- Delete `apps/awfy/src_target/awfy_target_runner.erl`, `lib/awfy/target_runner.ex`, the `print_target_summary/1` divergence in `BencheeRunner`, and the target-beam erlc block in `bin/install-otp-source.sh`.
- `bin/install-otp-source.sh` becomes macOS-only in practice (Windows uses its own PowerShell installer; Linux now goes through `Dockerfile.linux` for both modern and legacy). Worth renaming to `install-otp-source-mac.sh` for clarity, or keep general and document in the header.

**Tests:**
- Full `all` workflow run. Every pre-24 measure job uses the new path. No `-target-v2` job remains.
- Verify the `.benchee` file format matches what `Awfy.Compare.Data` already reads.

**Documentation deliverables:**
- `ARCHITECTURE.md`: rewrite the runner section. The goal is a future reader can answer "why is it like this?" without spelunking commits. Each design choice gets a paragraph of rationale, not just a one-line description. Concretely, document **why**:
  - peer-runner stays for OTP ≥ 24 instead of unifying everyone on the bundle path (free setup-beam Elixir bundles, no source-build cost);
  - the bundle is built on GHA-hosted Linux and consumed cross-platform (BEAM bytecode is platform-independent; pure-Elixir deps; per-platform OTP install supplies the platform-dependent NIFs);
  - the bundle's vendored deps strip dev/test entries (mix 1.9 walks the full transitive dep tree even with `MIX_ENV=prod`);
  - host Benchee is pinned to target Benchee compatibility (the `.benchee` file is `term_to_binary/1` of a `%Benchee.Suite{}` and host reads it with its own Benchee — schema must agree);
  - `build-linux` produces one Docker image consumed two ways (`docker run` on GHA for hermetic-userspace measurement, `docker cp` + bare-metal exec on AWS to avoid container overhead while keeping the build hermetic);
  - AWS uses Ubuntu LTS rather than Amazon Linux (matches GHA Ubuntu base + bullseye Docker image userspace, avoids OpenSSL 3 vs 1.1 clashes for pre-23 OTP, no kernel-tuning divergence between GHA and AWS pools);
  - prep-target-bundle and build-linux both run on GHA-hosted ubuntu-latest regardless of `runner_pool` (anything that doesn't need bare-metal benchmark accuracy belongs on free Actions minutes, not paid AWS time);
  - the `runner_pool=gha|aws` input defaults to `gha` (no AWS commitment until a pool is provisioned, push events stay free, nightly cron flip is one-line).
- `ISOLATION_POLICY.md`: add a paragraph on the legacy path's isolation model (fresh OS process per benchmark via `System.cmd`, stronger than peer's same-OS-process isolation but with higher startup cost). Cross-reference the rationale comments in `ARCHITECTURE.md`.
- Delete references to the Erlang harness from any markdown that mentions `awfy_target_runner.erl` or the calibration pass; replace with a note that "this used to exist; see git history if you're curious why it was retired" so future archaeology has a trail.
- `SETUP.md`: drop the "manual pre-24 measurement via target-runner" workflow if it's documented; replace with the bundle-based equivalent. Document the OTP × Elixir version pin matrix and *why* those specific Elixir patches were chosen (latest Elixir per OTP major per the upstream compatibility table).

**Acceptance:** clean `all` run, dashboard regenerates correctly, deleted code stays deleted, all docs reflect the post-Phase-3 reality.

## AWS impact

The merged workflow with `runner_pool=gha` (Phase 0 default) costs nothing on AWS. The numbers below describe what happens after we flip the default to `aws` (or after a manual `workflow_dispatch` with `runner_pool=aws`).

Per the analysis in `cross-platform bundles + Option B`:

- One-time cold cost: ~$1 (one prep job per Elixir version, builds on free GHA-hosted Linux regardless of `runner_pool`).
- Per warm-cache `all` run: net **−$3** (calibration tax goes away, no rebuild needed).
- Per push event: ~$0 (push is pinned to `runner_pool=gha`, regen-only path unchanged).
- S3 footprint for bundle distribution to AWS measure jobs: ~600 MB across 4 bundles; ~$0.014/month.

**Additional savings from extending `build-linux` to cover pre-24** (Phase 2): pre-24 Linux OTP source builds (~7 min × ~13 SHAs × 2 arches ≈ 3 compute-hours) move from AWS bare-metal at job-time to free GHA build-time. **−$15 per cold full backfill on Linux**, $0 warm. Modern Linux already had this win today via the existing `build-linux` Docker images; we're just extending the same pattern to legacy.

The prep job and `build-linux` both stay on GHA-hosted Linux indefinitely — their outputs are pulled by AWS measure jobs as needed. The principle: anything not requiring bare-metal hardware accuracy stays on free GHA.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Vendored deps drift from upstream when we bump Benchee | `bin/refresh-target-deps.sh` automates the re-strip; CI runs it on demand and diffs the result. Upgrade chore documented in `apps/awfy_target_runner/README.md`. |
| Host Benchee version locked to target Benchee compat | Accept this. Document in the sub-project README. Today both are 1.5.0; bumping target Benchee triggers a bump of host Benchee. |
| Elixir benchmarks don't compile under Elixir 1.9 | Phase 2 measures this. If they don't, target keeps silently skipping Elixir on those OTPs, same as today. The new path doesn't make this worse. |
| OTP 20 patches break on a future macOS version | Pre-existing risk; not introduced by this change. We already maintain `patches/OTP-20.3/`. |
| Cache invalidation produces 12-min cold builds when nobody expected one | Cache key includes patch hashes; only patch updates trigger rebuilds. Bumping a vendored dep triggers a rebuild. Both are intentional. Acceptable. |
| Cross-platform `.beam` portability assumption fails on some platform | Confirmed in plan analysis — pure-Elixir deps + platform-independent BEAM bytecode + per-platform target OTP. No NIFs in Benchee/deep_merge/statistex. Phase 2 verifies in CI. |

## Open questions for review

1. **Where should `Awfy.Runner` live?** Options: `lib/awfy/runner.ex` (top-level, replacing both peer and target conceptually but only doing target), or `lib/awfy/target_runner.ex` (replace in place, keep the name). The first is cleaner; the second has less rename churn but invites confusion with the deleted module.

Do the first.

2. **Should the Phase 2 toggle be an env var (`AWFY_USE_TARGET_BUNDLE=1`), a `mix awfy.measure --runner=bundle` flag, or a workflow `inputs:`?** Env var is least intrusive; flag is most discoverable. Flag is probably right.

Do it as a flag.

3. **Bundle distribution on AWS in Phase 1 or defer?** With the merged workflow from Phase 0, the `runner_pool=aws` branch already exists in the YAML — so the `aws s3 cp` upload/download step costs nothing to add now (skipped when `runner_pool=gha`). Slight preference to add it in Phase 1 alongside `prep-target-bundle` so the AWS path is fully wired the moment a runner pool comes online.

do it now.

4. **Windows pre-24 — confirm we keep building OTP on the Windows runner**, since only Elixir+deps come from the Linux-built bundle. The OTP install step on Windows is unchanged. Just want explicit sign-off that `install-otp-windows.ps1` is in scope as-is.

keep as is.

5. **Does the merged workflow keep separate `concurrency:` groups for push vs schedule events?** Today both files have their own `concurrency:` group; merging them into one workflow means a long-running schedule run could cancel an in-flight push smoke test if both share the workflow name. Probably want `concurrency: { group: bench-${{ github.event_name }}-${{ inputs.refs }}, cancel-in-progress: ... }` to keep them isolated. Not blocking but worth deciding before Phase 0 lands.

use your suggestion

## Files affected

**New:**
- `apps/awfy_target_runner/{mix.exs,lib/awfy/target_runner.ex,deps/...}`
- `bin/{build-target-bundle.sh,install-elixir-source.sh,refresh-target-deps.sh}`
- `lib/awfy/runner.ex`

**Modified:**
- `lib/awfy/benchee_runner.ex` (single-line dispatch flip in Phase 3)
- `bin/install-otp-source.sh` (drop the target-beam erlc block in Phase 3; effectively becomes macOS-only)
- `bin/resolve-fill-needs.sh` (drop modern/legacy split in Phase 3)
- `.github/workflows/bench.yml` (Phase 0: absorbs `bench-test.yml` and gains the `runner_pool` input; Phase 2: add `prep-target-bundle`, extend `build-linux` matrix to pre-24 OTPs, update the `-target` install steps to pull Docker image + bundle)
- `mix.exs` (add `awfy_target_runner` umbrella sub-app)
- `ARCHITECTURE.md` (Phase 0 + Phase 2 + Phase 3 incremental updates as runner story changes; Phase 3 owns the rationale-rich rewrite per Goal 5)
- `SETUP.md` (Phase 0 + Phase 1 + Phase 2 + Phase 3 — workflow naming, target-Elixir local builds, AWS pool prerequisites, post-Phase-3 cleanup)
- `ISOLATION_POLICY.md` (Phase 3 — legacy-path isolation paragraph)
- `terraform/README.md` (Phase 2 — Ubuntu AMI selection, runner-pool labels)

**Deleted (Phase 0):**
- `.github/workflows/bench-test.yml` (folded into the merged `bench.yml`)

**Deleted (Phase 3):**
- `apps/awfy/src_target/awfy_target_runner.erl`
- `lib/awfy/target_runner.ex`
- `lib/awfy/peer_runner.ex` — **NOT deleted**; kept for the modern path

**Approximate net delta:** ~+370 LOC added, ~−800 LOC removed. Net ~−430 LOC across Phases 1–3, plus the workflow consolidation in Phase 0 nets out to roughly even (one merged file vs two near-duplicates).

## Estimate

| Phase | Effort | Reversibility |
|---|---|---|
| 0 | ~half day (workflow merge + `runner_pool` input + GHA parity test) | Easy — revert to two-file layout |
| 1 | ~1 day (sub-project skeleton, build scripts, smoke test) | Trivial — additive only |
| 2 | ~1 day (parallel CI jobs, parity validation) | Easy — toggle off the new jobs |
| 3 | ~half day (dispatch flip, deletes, cleanup) | Hard — old code is gone |

Total: ~3 days of focused work, with natural review/merge points after each phase.
