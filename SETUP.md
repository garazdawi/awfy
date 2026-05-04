# Setup — `bench.yml` workflow

The `.github/workflows/bench.yml` workflow runs the AWFY suite against
`erlang/otp` on a daily schedule (or via `workflow_dispatch`) and
publishes results to the `gh-pages` branch. Steps below are the
one-time setup required by the repo owner.

## 1. Repository settings

### Pages
Settings → Pages → Source: **Deploy from a branch** → Branch: `gh-pages` → `/ (root)`.
The workflow creates `gh-pages` on first run if it doesn't exist.

### Actions permissions
Settings → Actions → General → Workflow permissions: **Read and write**.
The workflow uses `permissions:` to grant only what it needs, but the
repo-level setting must allow it.

### GHCR
The `build-linux` job pushes the benchmark image to
`ghcr.io/<owner>/<repo>`. The `GITHUB_TOKEN` has push access to GHCR
within the same repo by default — no extra setup. Make the package
public (Packages → Settings → Change visibility) so the AWS runners can
pull anonymously, or configure GHCR auth on the runners.

## 2. AWS CodeBuild as GitHub Actions runner

The Linux and Windows measure jobs use AWS CodeBuild as a self-hosted
GHA runner. AWS handles the instance lifecycle; you pay per build
minute. Compute classes are sized so each benchmark process owns one
physical core (and its hyperthread sibling on Intel) — see
`CLOUD_BENCH_PLAN.md` § CPU pinning.

### One-time AWS setup

1. **Connect AWS to GitHub.** AWS Developer Tools console →
   *Connections* → *Create connection* → GitHub → authorize the AWS
   GitHub App on this repo. Note the connection ARN.

2. **Create three CodeBuild projects** with these exact names:

   | Project name | Compute (EC2-class) | OS / arch |
   |--------------|---------------------|-----------|
   | `awfy-bench-linux-x86_64` | `c6i.4xlarge` (16 vCPU, 32 GB) | Linux x86_64 |
   | `awfy-bench-linux-arm64`  | `c7g.4xlarge` (16 vCPU, 32 GB, Graviton 3) | Linux ARM64  |
   | `awfy-bench-windows`      | `c6i.4xlarge` (16 vCPU, 32 GB) + Windows | Windows x86_64 |

   For each:
   - Source: GitHub via the connection from step 1, this repo.
   - Webhook events: leave **disabled** — GHA pulls the runner.
   - Environment: select **"Custom Image"** or AWS-managed standard
     image with EC2 launch type so you can pin instance type
     (CodeBuild's pre-baked compute classes top out at general1.large
     and don't expose c6i directly; use EC2 reserved capacity to get
     the exact instance type).
   - For Linux projects, enable **privileged mode** (Docker-in-Docker
     is required for the `docker pull` + `docker run` flow).
   - Service role: needs `codeconnections:UseConnection`,
     `logs:*`, plus `ec2:*` for the EC2-launch path.

3. **AMI quiescence (Linux).** Bake a minimal AMI for each Linux
   project that:
   - Disables `irqbalance` and `cpufreq` ondemand governors (set to
     `performance`).
   - Mounts `/tmp` as `tmpfs`.
   - Doesn't run `fstrim`/`updatedb`/cron-noisy services during
     benchmarks.
   - On Intel, leaves SMT enabled — the workflow uses
     `--cpuset-cpus=0` to avoid scheduling on vCPU 0's sibling
     (vCPU 8 on c6i.4xlarge); this gets us sibling-isolation
     without disabling SMT box-wide.

   ARM64 (`c7g.4xlarge`, Graviton 3) has no SMT — vCPU 0 is one
   physical core directly.

4. **Workflow `runs-on` resolution.** The matching syntax in the
   workflow is:
   ```yaml
   runs-on:
     - codebuild-<project-name>-${{ github.run_id }}-${{ github.run_attempt }}
   ```
   No additional config needed in this repo — CodeBuild intercepts the
   job at AWS's end via the GitHub App connection.

### Per-sweep cost (rough — pinned 4xlarge tier)

| Job | Instance | Wall | Rate | Cost |
|-----|----------|------|------|------|
| `measure-linux x86_64 jit/emu` | c6i.4xlarge | ~5 min × 2 | $0.68/h | ~$0.11 |
| `measure-linux arm64 jit/emu`  | c7g.4xlarge | ~5 min × 2 | $0.58/h | ~$0.10 |
| `measure-windows jit`          | c6i.4xlarge + Win | ~7 min | $1.08/h | ~$0.13 |
| `measure-linux-target` (legacy OTP, both archs/flavors) | as above | ~7 min × 4 | mix of c6i/c7g | ~$0.30 |

Total per full cloud sweep including legacy OTPs: **~$0.65**.
Annualised numbers:

| Cadence | Cost |
|---------|------|
| Weekly cron only | ~$76/yr |
| Per-perf-relevant-commit (~200/yr) | ~$287/yr |
| Daily | ~$524/yr |

See `CLOUD_BENCH_PLAN.md` § Cost per sweep for the breakdown.

macOS isn't part of the cloud cost — runs locally via
`mix awfy.fill` on your M5; see section 3.

## 3. macOS — local fill task

The M5 is your daily-driver dev machine, not a CI box. Rather
than register it as a self-hosted GHA runner that gets jobs
forced on it while you're working, macOS measurements are driven
locally by `mix awfy.fill`. The cloud workflow publishes Linux +
Windows results to `gh-pages`; the fill task notices what's
missing for `macos-arm64` and runs those at your leisure.

### Prerequisites

```bash
xcode-select --install                  # one-time
brew install autoconf openssl@3 ncurses # OTP build deps
```

### Running

When you have a moment — lunch break, end of day, between meetings —
in the awfy repo:

```bash
mix awfy.fill                       # find missing SHAs, run, commit locally
mix awfy.fill --max 3               # cap at 3 SHAs per session
mix awfy.fill --since 2026-04-01    # only SHAs newer than this
mix awfy.fill --dry-run             # show what would run, do nothing
```

The task fetches `gh-pages` into a `_pages/` worktree, runs each
missing measurement under a fresh OTP build (the install scripts
are content-addressed by SHA so re-runs short-circuit), and
commits new run-dirs locally. **It never pushes** — review with
`git -C _pages log -1 --stat`, then publish with:

```bash
git -C _pages push origin gh-pages
```

### Practical pattern

- **Drain whenever**. The cloud workflow doesn't wait on macOS;
  Linux + Windows publish immediately. Your fill commits land on
  whatever cadence works for you — daily, weekly, after a holiday.
- **Batches naturally**. If the M5 was off for a week, the next
  fill picks up all the missed SHAs in one session.
- **No registration to maintain**. There's no `actions-runner`
  process to reinstall after macOS updates, no token to rotate,
  no launchd plist to forget about.

The same `mix awfy.fill` works on any platform — handy if you
ever want to fill from a Windows VM or a Linux ARM box without
adding it to CodeBuild.

## 4. Windows installer resolution (no setup needed)

The Windows job picks the right installer automatically:

- **Tagged releases** (`OTP-28.0`, `v28.0`) → `otp_win64_<ver>.exe`
  from `erlang/otp` Releases.
- **Branch / SHA** (`master`, `<sha>`) → the `otp_win32_installer`
  artifact from the most recent `Build and check Erlang/OTP` run on
  that ref. (The artifact name is legacy "Win32" nomenclature; the
  file inside is the 64-bit installer.)
- **Override** — set repository variable `OTP_WIN_INSTALLER_URL`
  (Settings → Variables → Actions) to a stable URL to bypass both
  paths. Useful if you need a specific installer build that isn't
  the upstream-CI one.

The artifact path uses the `GITHUB_TOKEN` already granted to the
workflow (via `permissions: actions: read`); no extra secret needed.

## 5. First-run sanity check

1. **Manually trigger the workflow** with `workflow_dispatch`,
   `otp_refs=master`. The workflow has no `skip_macos` toggle —
   macOS isn't part of `bench.yml` at all (it's local-fill, see
   section 3).
2. Wait for `build-linux` to push images to GHCR.
3. Watch `measure-linux` jobs queue and run on CodeBuild — first run
   will be slow (cold layer cache, ~15 min total). Subsequent runs
   reuse the cache.
4. Confirm `publish` creates the `gh-pages` branch and pushes.
5. Visit `https://<owner>.github.io/<repo>/` — should show the AWFY
   dashboard with Linux + Windows timings.
6. On the M5: `mix awfy.fill` to add the macOS-arm64 column, then
   `git -C _pages push origin gh-pages` to publish.

## 6. Backfill (one-time)

Once the first sanity-check sweep is green, kick off the history
backfill: one measurement per OTP feature release at its latest
patch. Trigger `workflow_dispatch` with the full feature-release
list as `otp_refs`, e.g.:

```
20.0,20.1,20.2,20.3,21.0,21.1,21.2,21.3,...,28.0,28.1,28.2,28.3,28.4,28.5,master
```

About 40 sweeps total (~$26 on AWS, ~7 hours of M5 time on the
macOS side via `mix awfy.fill`). After backfill the weekly cron
keeps the recent feature releases current; new patch tags are
benchmarked one-off via additional `workflow_dispatch` triggers.
See `CLOUD_BENCH_PLAN.md` § Backfill and steady-state cadence.

For a no-AWS dry run of the wiring, use the parallel
`bench-test.yml` workflow — it runs the same matrix on
GHA-hosted runners (free, noisy timings). See
`CLOUD_BENCH_PLAN.md` § Phase 0 for what it does and doesn't
validate.
