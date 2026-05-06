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
- New sibling app at `apps/awfy_target_runner/` (under `apps/` but NOT path-depended-on by the root `mix.exs` — see resolved decision #10) with its own `mix.exs` and one Elixir module: `Awfy.TargetRunner` (the `main/1` script with arg parsing and `Benchee.run/2` invocation).
- Vendored deps under `apps/awfy_target_runner/deps/{benchee,deep_merge,statistex}/` with `mix.exs` files stripped of dev/test deps. The strip is a one-time edit; subsequent dep upgrades go through a small `bin/refresh-target-deps.sh` script that re-fetches and re-strips.
- `bin/build-target-bundle.sh <otp_install_dir> <elixir_version>`. Consumes a pre-built OTP install directory (built by `build-linux`'s Docker image on CI, or `bin/install-otp-source.sh` locally — see resolved decision #12). Idempotent: builds Elixir against the supplied OTP → mix-compiles vendored deps → mix-compiles the runner module → tars `bin/`, `lib/elixir/ebin`, `_build/prod/lib/*` into `target_bundle.tar.gz`.
- `bin/install-elixir-source.sh <elixir_version> <otp_prefix>`. Clones the elixir tag, makes against the target OTP, no install.
- `bin/extract-otp-from-image.sh <image>`. `docker create` + `docker cp /opt/otp` + `docker rm` to pull an OTP install out of a per-OTP-SHA `build-linux` image — used by `prep-target-bundle` to feed `bin/build-target-bundle.sh` without a redundant source build.

**Tests:**
- Unit tests for the runner module's argv parsing and `.benchee` output shape.
- Local smoke test: build OTP-20.3 and the bundle, run the runner against a one-line benchmark, verify the produced `.benchee` is readable by `Awfy.Compare.Data` on the host.

**Acceptance:** `bin/build-target-bundle.sh 20 1.9.4` produces a bundle whose runner can be invoked end-to-end on the local Mac, output loaded by `Awfy.Compare.Data.load/1` without errors. Nothing in the existing measure path changes; nothing in CI runs the new code yet.

### Phase 2 — `Awfy.Runner` and `prep-target-bundle` workflow (parallel install, no replacement yet)

**Deliverables:**
- New `lib/awfy/runner.ex` (~80 LOC). Single function: `run(target_dir, module, inner_iter, opts)` shells out to the target Elixir bundle, blocks, returns the `.benchee` path. Replaces `Awfy.TargetRunner` in spirit but doesn't yet activate.
- `prep-target-bundle` workflow job (matrix over four OTP/Elixir pairs) on `ubuntu-latest`. Pulls the per-OTP-SHA `build-linux` image from GHCR, calls `bin/extract-otp-from-image.sh` to lift `/opt/otp` out, and feeds the path to `bin/build-target-bundle.sh`. Uses `actions/cache` keyed by `(elixir_version, otp_sha, sub-app source hash, vendored-deps hash)` — *no* OTP source-build cost on prep, because the OTP install is reused from `build-linux`. Outputs the bundle as a workflow artifact (and S3 when `runner_pool=aws`).
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

## Resolved decisions

These were open questions during plan drafting; recording the answers here so the implementing agent doesn't have to re-ask.

1. **`Awfy.Runner` lives at `lib/awfy/runner.ex` (top-level).** Cleaner than reusing `lib/awfy/target_runner.ex`, and the old `target_runner.ex` is being deleted in Phase 3 anyway — no rename collision.

2. **Phase 2 runner-selection is a `mix awfy.measure --runner=bundle` flag**, not an env var. Most discoverable, fits the existing CLI shape. Default value is the existing path until Phase 3 flips the dispatch.

3. **Bundle distribution to AWS lands in Phase 1** alongside `prep-target-bundle`, not deferred. The `aws s3 cp` step is gated on `runner_pool == 'aws'` so it's a no-op while the default is `gha`. Wiring it now means flipping the default later is a one-line change.

4. **Windows pre-24 keeps `install-otp-windows.ps1` unchanged.** Only Elixir + deps come from the Linux-built bundle; target OTP on Windows still installs through the existing PowerShell path. Linux-built BEAM bytecode runs on Windows OTP without modification.

5. **Concurrency groups are separated per event type and ref-set.** The merged workflow uses `concurrency: { group: bench-${{ github.event_name }}-${{ inputs.refs }}, cancel-in-progress: false }`. A long-running schedule run can't cancel an in-flight push smoke test, and two pushes for the same ref still queue rather than racing.

6. **Bundle extraction from the Linux Docker image uses `docker create` + `docker cp`**, not `docker save | tar` and not a `FROM scratch` final stage. Reasoning: simplest mechanics, doesn't require restructuring `Dockerfile.linux`, and `docker rm` cleans up the throwaway container. `bin/extract-otp-from-image.sh` ships as a tiny wrapper:
   ```sh
   id=$(docker create "$IMAGE")
   docker cp "$id":/opt/otp ./otp
   docker rm "$id"
   ```

7. **AWS runner labels follow the schema `["self-hosted", "aws", "linux", "<arch>"]`** where `<arch>` is `x86_64` or `arm64`. Terraform provisioning will register runners with these labels. The macOS leg stays on the user's M5 (per memory `project_macos_runner.md`); Windows stays on GHA-hosted Windows under `runner_pool=gha` until a Windows AWS pool is justified by demand.

8. **`bin/refresh-target-deps.sh` is a maintenance script** for upgrading the vendored target deps. Run from a TLS-current host (any modern Elixir), it: re-fetches the pinned versions of benchee/deep_merge/statistex from hex via `mix deps.get`, copies the new sources into `apps/awfy_target_runner/deps/`, re-applies the dev/test stripping (see Appendix), and verifies the resulting tree compiles under each pinned target Elixir. Idempotent — running it with no upstream changes is a no-op.

9. **Parity-check methodology in Phase 2.** `bin/compare-target-paths.sh` (small new helper) takes two run-directories produced by the same OTP ref — one from `-target` (current), one from `-target-v2` (new) — and emits a per-benchmark median delta (`(new - old) / old`). Acceptance: aggregate geomean delta within ±5% across all benchmarks; no individual benchmark's |delta| exceeds 15%. Larger deltas mean the two paths are measuring different things and need investigation before Phase 3 lands.

10. **Sibling app under `apps/`, NOT a path-dep of the root `mix.exs`.** The root project (`mix.exs:19-25`) is deliberately not a Mix umbrella; `apps/<name>/` already houses standalone apps that are individually compilable, including under a different OTP/Elixir than the runner. `apps/awfy_target_runner/` follows the same shape: its presence under `apps/` is convention, not a dependency relationship. Concrete consequences:
    - The root `mix compile` does not descend into the sub-app. Vendored target-pinned deps with stripped dev/test trees never enter the host `_build`.
    - The duplicate `Awfy.TargetRunner` module name (host `lib/awfy/target_runner.ex` until Phase 3 deletes it; sub-app `apps/awfy_target_runner/lib/awfy/target_runner.ex` from Phase 1 onward) does not collide — they compile into separate `_build` trees and are loaded by different VMs (host vs target-erl-via-`System.cmd`).
    - The plan's earlier "umbrella sub-app" wording is loose; "sibling app under `apps/`" is the precise description.

11. **`mix precommit` runs the sub-app's tests + every benchmark app's tests.** Since the sub-app isn't a path-dep, `mix test` at the root won't reach it. The root `aliases/0` in `mix.exs` gains `mix cmd --cd apps/awfy_target_runner mix test` (added in Phase 1) plus equivalent invocations for any `apps/<bench>/` that ships its own `test/` tree. This keeps local pre-commit checks symmetric with what CI exercises and catches sub-app regressions before they ship.

12. **`bin/build-target-bundle.sh` consumes a pre-built OTP install directory.** Signature is `build-target-bundle.sh <otp_install_dir> <elixir_version> [<output_path>]`. The script does not source-build OTP itself.
    - On CI, `prep-target-bundle` (Phase 2) extracts `/opt/otp` from the per-OTP-SHA Docker image produced by the (extended-to-pre-24) `build-linux` matrix via `bin/extract-otp-from-image.sh`, then passes that directory to the bundle script. OTP is built once per SHA across the whole workflow.
    - Locally on macOS, the developer pre-builds OTP via the existing `bin/install-otp-source.sh` and points the bundle script at the resulting prefix. No Docker required for local dev.
    - Eliminates the duplicate ~7-min OTP source-build that the plan's earlier "Idempotent: builds OTP from source (if not cached)" wording implied.

## Files affected

**New:**
- `apps/awfy_target_runner/{mix.exs,lib/awfy/target_runner.ex,test/...,deps/...}`
- `apps/awfy_target_runner/README.md`
- `bin/{build-target-bundle.sh,install-elixir-source.sh,refresh-target-deps.sh,extract-otp-from-image.sh,compare-target-paths.sh}`
- `lib/awfy/runner.ex`

**Modified:**
- `lib/awfy/benchee_runner.ex` (single-line dispatch flip in Phase 3)
- `bin/install-otp-source.sh` (drop the target-beam erlc block in Phase 3; effectively becomes macOS-only)
- `bin/resolve-fill-needs.sh` (drop modern/legacy split in Phase 3)
- `.github/workflows/bench.yml` (Phase 0: absorbs `bench-test.yml` and gains the `runner_pool` input; Phase 2: add `prep-target-bundle`, extend `build-linux` matrix to pre-24 OTPs, update the `-target` install steps to pull Docker image + bundle)
- `mix.exs` (Phase 1 — extend the `precommit` alias to run `mix test` in `apps/awfy_target_runner/` and in any benchmark app under `apps/<bench>/` that ships a `test/` tree; the sub-app itself is **not** added to the root `deps/0` — see resolved decision #10)
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

## Follow-ups

Phases 0-3 landed (commits `2de710c6` plan resolutions, `55e5c99c` Phase 0, `b6332220` Phase 1, `cb1cd87e` Phase 2, `2d3bbdb4` Phase 3). Items below are deliberate deferrals or unverified-in-this-pass acceptance steps:

### Validation we still owe

1. ✅ **Phase 1 acceptance — local end-to-end smoke.** Done.
   `bin/install-otp-source.sh OTP-20.3` source-built OTP 20.3 on macOS arm64 with the existing patch stack; `bin/build-target-bundle.sh` produced a 5.3 MB bundle; `erl -s 'Elixir.Awfy.TargetRunner' main -extra …` against a one-line `bench_smoke` benchmark wrote a `.benchee` file that `:erlang.binary_to_term/1` round-trips into a `%Benchee.Suite{}` via the host project's Benchee — schema match holds.
   Also exercised `Awfy.Runner.run/4` (the host wrapper) directly: `{:ok, suite}`, median 1.0µs, n=1M.

   One snag worth keeping noted for next time: `bin/build-target-bundle.sh` once exited 0 right after `install-elixir-source.sh` returned, without writing the tarball — couldn't reproduce. The script now ends with a `[ -s "$OUTPUT" ]` sanity check so a future silent regression fails loudly.

2. ✅ **Phase 2/3 acceptance — first CI run on push.** Done.
   Run `25430299994` (head `2b179a4d`) finished `success` with every job green: resolve, modern build-linux × 4, legacy build-linux-target × 2, prep-target-bundle (21, 1.11.4) + the three skip-path entries, modern measure-linux × 8 + measure-windows × 2 + measure-macos × 4, **bundle-path measure-{linux × 2, windows, macos}-target** for OTP-21.3, publish.

   Run history (push trigger, `refs=21,28,master`, `runner_pool=gha`) — four runs on the way to a clean smoke:
   - **`25428842776`** (head `86703a4c`): modern path fully green. Legacy `build-linux-target` failed because the merged Dockerfile.linux's `app` stage installs the precompiled `elixir-otp-${ELIXIR_OTP_MAJOR}.zip` and runs `mix deps.get`, but resolve picks `elixir_bundle=28` for OTP 21 (Elixir 1.19 build) which is incompatible with the OTP 21.3 emulator (`undef elixir:start_cli/0`). All legacy chain skipped.
   - **`25429119193`** (head `790d9805`): fix — `build-linux-target` now passes `target: otp-build` to docker/build-push-action so the legacy build stops at the OTP stage instead of running through the Elixir-installing app stage. Legacy build-linux-target green on both arches; `prep-target-bundle` then failed with `bin/erl: exec: /usr/local/lib/erlang/erts-10.3.5.19/bin/erlexec: not found` — OTP bakes the install prefix into its wrapper scripts at build time, and after extracting from `/usr/local` in the image to `$PWD/otp` on the host, the scripts still reference the original path.
   - **`25429667553`** (head `066fe3f6`): fix — `bin/extract-otp-from-image.sh` now runs OTP's own `Install -minimal <new-rootdir>` script after relocation, which is the upstream-documented mechanism for re-baking ROOTDIR. The run was queue-pruned by GHA when the next push landed; `25429751957` (head `33a5ec30`) carried the same fix and ran. `prep-target-bundle (21, 1.11.4)` then failed at `bin/install-elixir-source.sh`'s `[ -x "$ELIXIR_DIR/bin/elixir" ]` check — `make`'s stdout was being captured by `$( ... )` in `build-target-bundle.sh` along with the install path, so `$ELIXIR_DIR` ended up multi-line. The deeper problem the warnings flagged: bullseye's libssl1.1 isn't on Ubuntu 24.04, so the extracted OTP's crypto NIF couldn't load. Crypto isn't strictly needed for our path, but the warnings would become runtime crashes if any code tickled `:crypto.X`.
   - **`25430299994`** (head `2b179a4d`): two-fix push: `make ... 1>&2` in install-elixir-source.sh, plus a new `EXTRA_CONFIGURE` build-arg on Dockerfile.linux's `otp-build` stage that build-linux-target uses to pass the `--without-ssl` flag resolve already computed for legacy OTPs. **All green.**

   What got proved end-to-end: the entire chain — legacy Docker image build with `--without-ssl` → image push to GHCR → `docker create` + `docker cp /usr/local` + `docker cp /opt/awfy_target` → `Install -minimal` rebake → `bin/install-elixir-source.sh` source-builds Elixir 1.11.4 against the relocated OTP → `bin/build-target-bundle.sh` mix-compiles vendored deps + sub-app + tarballs → upload to actions/upload-artifact → measure jobs `actions/download-artifact` + `tar xzf` + set AWFY_TARGET_ERL/BUNDLE/BEAMS → `mix awfy.measure` → `Awfy.BencheeRunner` dispatches to `Awfy.Runner` → `erl -s Elixir.Awfy.TargetRunner main -extra ...` against bench beams → bundle's `Awfy.TargetRunner.main/0` runs Benchee → writes `.benchee` → host `binary_to_term`s it back → publish stages results to gh-pages.

### Plan items we deferred during implementation

3. **`bin/resolve-fill-needs.sh` simplification (plan §197).** Collapse the 6 per-`(major, platform)` arrays into 3 per-platform `targets_*` arrays carrying `(otp_ref, elixir_version, …)` per entry. Pure cleanup post-Phase-3 — dispatch is unified, the per-major arrays exist only as a workflow-routing artefact. No behaviour change; smaller resolve script, smaller workflow.

4. **`bin/install-otp-source.sh` rename to `install-otp-source-mac.sh`** (plan §198). After Phase 3, Linux goes through `Dockerfile.linux` for both modern and legacy; this script is macOS-only in practice. Rename is cosmetic but makes the layout self-documenting. Header comment updated as the in-place alternative if rename feels too invasive.

5. **AWS runner-label scheme migration (resolved decision #7).** Move from `awfy-bench-linux-{x86_64,arm64}` / `awfy-bench-windows` to the structured `["self-hosted","aws","linux","<arch>"]` form. Touches Terraform AMIs, `bench.yml` `runs-on:` expressions, and `terraform/README.md`. Best done together when next adjusting the runner pool.

### Quality-of-life

6. **Add root `mix test` to `precommit`.** Currently `precommit` runs sub-app tests via the `Path.wildcard("apps/*/test")` loop but skips root `test/`. Now that the pre-existing `versioned_bench_test` failure is fixed, root is green. Adds ~13s but catches `BencheeRunner` regressions locally instead of in CI.

7. **Bundle distribution to AWS — exercise the S3 path.** The `aws s3 cp` step in `prep-target-bundle` is gated on `runner_pool=aws` *and* `vars.AWFY_TARGET_BUNDLE_S3_BUCKET != ''`. Wired but never run. When the AWS runner pool is committed, set the bucket var and validate the end-to-end fetch on the AWS side.

## Appendix — Prototype findings & gotchas

These are facts established by the OTP-20.3 + Elixir-1.9.4 + Benchee-1.5 prototype that proved the proposition. Documented here so the implementing agent doesn't re-discover each one painfully (each took 5–30 min of detour during the prototype).

### A. Vendored deps must drop their dev/test deps entirely

Symptom: `mix deps.compile` fails with `Could not find Hex, which is needed to build dependency :credo` even with `MIX_ENV=prod`, even with `override: true` declared in the parent project's `mix.exs`. Mix 1.9 walks the full transitive `deps()` list of every dep regardless of `MIX_ENV` and `only:` modifiers — it only filters at *build* time, not *resolution* time, and resolution-time SCM lookup demands hex registry access. Target OTP was built `--without-ssl`, so `mix local.hex` can't fetch.

Workaround (apply to vendored copies in `apps/awfy_target_runner/deps/`):

- `deps/benchee/mix.exs` — replace the `defp deps` body with just the runtime deps; drop `credo, ex_doc, excoveralls, dialyxir, doctest_formatter, ex_guard`. Also remove the `Version.compare/2 > "1.7.0"` branch that conditionally adds `{:table, "~> 0.1.0", optional: true}` — table is unused in our path and re-introduces the SCM-lookup problem. The remaining body should be:
  ```elixir
  defp deps do
    [
      {:deep_merge, path: "../deep_merge"},
      {:statistex, path: "../statistex"}
    ]
  end
  ```
- `deps/deep_merge/mix.exs` — replace `defp deps` body with `[]`. All entries are dev/test/docs.
- `deps/statistex/mix.exs` — replace `defp deps` body with `[]`. Same reason.

`bin/refresh-target-deps.sh` (deliverable in Phase 1) re-fetches and re-applies these edits programmatically — don't hand-edit each upgrade.

### B. OTP-20.3 source must come from the canonical erlang.org tarball

`https://github.com/erlang/otp/releases/download/OTP-20.3/otp_src_20.3.tar.gz` returns 404 — github releases only host pre-OTP-21 source on a few specific tags, and 20.3 isn't one of them.

`https://github.com/erlang/otp/archive/refs/tags/OTP-20.3.tar.gz` exists but **lacks the pre-generated `configure` script**. Running `./otp_build autoconf` to regenerate it trips a BSD-`sed` locale issue on macOS ("RE error: illegal byte sequence") unless run with `LC_ALL=C ./otp_build autoconf`. Even then, some sub-`configure` scripts (e.g. `lib/asn1/configure`) silently fail to generate.

The canonical path: `https://erlang.org/download/otp_src_20.3.tar.gz`. Has the pre-generated configure scripts intact. Caveat: the CDN is sometimes very slow (~10 KB/s sustained on bad-day nodes); a fresh `curl` connection often gets a different node and bursts to 2+ MB/s. Retry rather than wait.

The existing `bin/install-otp-source.sh` already prefers github releases → erlang.org → prebuilt artifact — for OTP 20 it falls through to erlang.org and works once the network is cooperative. No script changes needed; just be aware the github path 404s.

### C. System Hex archive incompatibility

If a fresh Elixir 1.9 build is invoked with the user's existing `~/.mix/archives/hex-2.3.1-otp-28/` archive on the path, Mix tries to load it and fails with:

```
Error loading module 'Elixir.Hex':
  This BEAM file was compiled for a later version of the run-time system than 20.
  (Use of opcode 177; this emulator supports only up to 159.)
```

Workaround: `MIX_HOME=/tmp/elixir19_mix mix ...` to use a fresh archive directory. The build pipeline shouldn't need Hex at all (vendored deps), but mix loads installed archives unconditionally on startup. Always run target Elixir with an isolated `MIX_HOME`.

### D. Target beams require OTP-app priv-dir layout

`code:priv_dir(awfy)` in OTP only resolves if the beams sit in a directory shaped like an OTP app: `<libdir>/awfy-<vsn>/{ebin,priv}/`. If `AWFY_TARGET_BEAMS` points at a flat `ebin/` directory and `priv/` is a sibling instead of a peer-of-ebin, `priv_dir/1` returns `{:error, :bad_name}` and the Json benchmark function-clauses on `filename:join(priv_dir, ...)`.

Concrete: target build output goes into `<bundle>/lib/awfy_target_runner/{ebin,priv}/`. `bin/build-target-bundle.sh` should validate the layout before tarballing.

### E. `:erlang.system_info(:otp_release)` returns a charlist on OTP 20

Binary on OTP 21+. Any code in `target_runner.ex` that does `<>` concatenation on it (e.g. for log lines) needs `List.to_string/1` first or it crashes with `:erlang.byte_size/1` ArgumentError. Single sharp edge but unmistakable when it bites.

### F. Calibration-tax measurement (background for Phase 2 acceptance)

Earlier benchmarking (3 reps × Bounce/Json/Sieve × time=2s warmup=1s, OTP 28 host, target erl=host erl):

| Mode | Mean wall clock |
|---|---|
| Peer (current modern path) | 14.20s |
| Target (current legacy harness) | 24.19s |

Per-benchmark target-mode tax = ~3.4s, dominated by the 3-iteration calibration pass `Awfy.TargetRunner.run_raw(module, inner_iter, 3)`. For slow benchmarks (Sieve at 1.93s/iter) this is ~5.8s of pure overhead. The new bundle path **doesn't have this** — Benchee handles its own time budgeting natively, so the calibration disappears. Phase 2's parity check should see legacy-target wall clocks reduced by roughly this amount under the bundle path; if instead bundle-target is *slower*, something is wrong with the new path.

### G. Reference: minimal probe project that compiled cleanly

The prototype lived at `/tmp/elixir19_test/` (now gone — those paths are ephemeral). Its mix.exs:

```elixir
defmodule DepProbe.MixProject do
  use Mix.Project
  def project do
    [app: :dep_probe, version: "0.1.0", elixir: "~> 1.9", deps: deps()]
  end
  def application, do: []
  defp deps do
    [
      {:benchee,    path: "deps/benchee",    override: true},
      {:deep_merge, path: "deps/deep_merge", override: true},
      {:statistex,  path: "deps/statistex",  override: true}
    ]
  end
end
```

Compile invocation that worked:
```sh
MIX_HOME=/tmp/elixir19_mix MIX_ENV=prod \
  PATH=/tmp/otp20_install/bin:/tmp/elixir_proto/elixir/bin:$PATH \
  /tmp/elixir_proto/elixir/bin/mix deps.compile
```

Output: `==> deep_merge … Generated deep_merge app / ==> statistex … Generated statistex app / ==> benchee … Generated benchee app`.

Smoke test that ran end-to-end (2 trivial benchmarks, ~50k samples in 1s, valid statistics):
```sh
MIX_HOME=/tmp/elixir19_mix MIX_ENV=prod PATH=... \
  /tmp/elixir_proto/elixir/bin/elixir smoke.exs
```

This is the exact shape Phase 1's `bin/build-target-bundle.sh` should reproduce, just with the smoke test replaced by the bundling step.
