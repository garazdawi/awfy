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
minute (~$0.005/min for Linux x86 `general1.small`).

### One-time AWS setup

1. **Connect AWS to GitHub.** AWS Developer Tools console →
   *Connections* → *Create connection* → GitHub → authorize the AWS
   GitHub App on this repo. Note the connection ARN.

2. **Create three CodeBuild projects** with these exact names:

   | Project name | Compute | OS / arch |
   |--------------|---------|-----------|
   | `awfy-bench-linux-x86_64` | `general1.small` (or larger) | Linux x86_64 |
   | `awfy-bench-linux-arm64`  | ARM equivalent               | Linux ARM64  |
   | `awfy-bench-windows`      | Windows medium               | Windows x86_64 |

   For each:
   - Source: GitHub via the connection from step 1, this repo.
   - Webhook events: leave **disabled** — GHA pulls the runner.
   - Environment image: AWS-managed standard image is fine; the workflow
     installs everything it needs.
   - For Linux projects, enable **privileged mode** (Docker-in-Docker is
     needed to `docker pull` and `docker run` the benchmark image).
   - Service role: needs `codeconnections:UseConnection`,
     `logs:*`, `ecr-public:GetAuthorizationToken` (for GHCR pulls if
     image is private — public image needs nothing extra).

3. **Workflow `runs-on` resolution.** The matching syntax in the
   workflow is:
   ```yaml
   runs-on:
     - codebuild-<project-name>-${{ github.run_id }}-${{ github.run_attempt }}
   ```
   No additional config needed in this repo — CodeBuild intercepts the
   job at AWS's end via the GitHub App connection.

### Per-sweep cost (rough)

| Job | CodeBuild compute | Wall | Cost |
|-----|-------------------|------|------|
| `measure-linux x86_64 jit` | `general1.small` (3 GB, 2 vCPU) | ~10 min | ~$0.05 |
| `measure-linux x86_64 emu` | same | ~10 min | ~$0.05 |
| `measure-linux arm64 jit/emu` | ARM equivalent | ~10 min × 2 | ~$0.10 |
| `measure-windows jit/emu`  | Windows medium                  | ~20 min × 2 | ~$0.30 |

Total: **~$0.50 per full cloud sweep**. Daily for a year ≈ **$180**.
Per-perf-relevant-commit (~200/yr) ≈ **$100**. (CodeBuild charges
per build-minute including queue setup, vs. raw EC2 per-second
billing; migrate to ephemeral EC2 runners via Terraform if the
daily cost becomes annoying.)

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

## 4. Optional: Windows installer URL for master commits

By default the Windows job resolves OTP refs that look like release
tags (`OTP-28.0`, `v28.0`) via GitHub Releases. For arbitrary master
SHAs, set repository variable `OTP_WIN_INSTALLER_URL` (Settings →
Variables → Actions) to a stable URL pattern. Examples:

- A static URL pointing at the latest upstream master installer
  artifact.
- An S3 bucket the operator publishes to via a separate cron job
  that mirrors upstream CI artifacts.

If unset, master sweeps will fail the Windows leg until configured.
The workflow's other legs continue normally.

## 5. First-run sanity check

1. **Manually trigger the workflow** with `workflow_dispatch`,
   `otp_ref=master`, `skip_macos=true` (skip M5 the first time).
2. Wait for `build-linux` to push images to GHCR.
3. Watch `measure-linux` jobs queue and run on CodeBuild — first run
   will be slow (cold layer cache, ~15 min total). Subsequent runs
   reuse the cache.
4. Confirm `publish` creates the `gh-pages` branch and pushes.
5. Visit `https://<owner>.github.io/<repo>/` — should show the AWFY
   dashboard with one set of timings.
6. Re-run with `skip_macos=false` once the M5 runner is registered.
