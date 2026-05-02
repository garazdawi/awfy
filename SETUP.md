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
| `measure-macos jit/emu`    | self-hosted (your M5)           | ~12 min × 2 | $0.00 |

Total: **~$0.50 per full sweep** on CodeBuild. (Higher than the
$0.10 in `CLOUD_BENCH_PLAN.md` because CodeBuild charges per
build-minute including queue setup, vs. raw EC2 per-second billing.
Migrate to ephemeral EC2 runners via Terraform if the daily cost
becomes annoying.)

Daily for a year ≈ **$180**. Per-perf-relevant-commit (~200/yr) ≈ **$100**.

## 3. macOS self-hosted runner

On the M5:

```bash
# 1. Get a registration token from Settings → Actions → Runners → New self-hosted runner
mkdir ~/actions-runner && cd ~/actions-runner
curl -fL -o runner.tar.gz \
    https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64-<latest>.tar.gz
tar xzf runner.tar.gz

# 2. Configure with the labels the workflow expects
./config.sh --url https://github.com/<owner>/<repo> --token <reg-token> \
    --labels macos-m5 --name m5

# 3. Run as a launchd service so it survives reboots
./svc.sh install
./svc.sh start
```

Prerequisites the runner needs locally (one-time):
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew, then `brew install autoconf openssl@3 ncurses`
- Optional but recommended: a fast SSD for the OTP source builds the
  runner does on every sweep.

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
