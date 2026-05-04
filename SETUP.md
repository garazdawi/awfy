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

## 2. Terraform-managed ephemeral self-hosted runners

The Linux and Windows measure jobs run on ephemeral EC2 instances
provisioned per-job by the [`philips-labs/terraform-aws-github-runner`][module]
module. A Lambda watches GitHub for `workflow_job` queued events,
spins up a fresh EC2 instance pinned to a specific instance type,
the runner registers as ephemeral (one-shot), runs the job, the
instance terminates. Per-second billing on raw EC2 — no idle
charges. The pinning matters: AWFY trend lines compare runs across
years, and a vCPU on `c6i.4xlarge` is a known quantity in a way
that "8 vCPUs of whatever CodeBuild gave you today" is not.

[module]: https://github.com/philips-labs/terraform-aws-github-runner

| Pool label | Instance | Purpose |
|------------|----------|---------|
| `awfy-bench-linux-x86_64` | `c6i.4xlarge` | Linux x86_64 measurements |
| `awfy-bench-linux-arm64`  | `c7g.4xlarge` (Graviton 3) | Linux ARM64 measurements |
| `awfy-bench-windows`      | `c6i.4xlarge` + Windows | Windows measurements |

The Terraform module — `terraform/main.tf` plus `variables.tf` /
`outputs.tf` — is the source of truth. This section walks through
the operator-side actions needed before `terraform apply` succeeds.

### One-time AWS setup

Pick an AWS region with `c6i.4xlarge` and `c7g.4xlarge` capacity —
`us-east-1`, `us-west-2`, and `eu-west-1` all qualify. Stay in
that region for every step below; the region is sticky in console
URLs (`?region=us-east-1`) and a mismatch is the single most common
"I can't see my resources" failure.

You'll need: AWS CLI v2 with credentials configured (`aws sso
login` or static keys), Terraform ≥ 1.5 (`brew install terraform`
or `tfenv install latest`), and an existing VPC + at least one
subnet with outbound internet (default VPC works).

#### 2.1. Create a GitHub App for the runners

The module needs one GitHub App that can register self-hosted
runners and receive `workflow_job` webhooks. Create it once,
share it across all three pools.

1. Go to `https://github.com/settings/apps/new` (or, for an org:
   `https://github.com/organizations/<org>/settings/apps/new`).
2. **Name**: anything memorable, e.g. `awfy-bench-runners`.
3. **Homepage URL**: the awfy repo URL.
4. **Webhook**:
   - **Active**: checked.
   - **Webhook URL**: leave blank for now — you'll fill this in
     after `terraform apply` prints the endpoint (step 2.4).
   - **Webhook secret**: generate one with
     `openssl rand -hex 32` and paste it. Save the same value;
     you'll feed it to Terraform.
5. **Repository permissions**:
   - **Actions**: Read-only.
   - **Administration**: Read & write (needed to register
     runners against the repo).
   - **Checks**: Read-only.
   - **Metadata**: Read-only (mandatory).
6. **Subscribe to events**: tick **Workflow job**.
7. **Where can this GitHub App be installed?**: *Only on this
   account*.
8. **Create GitHub App**. After creation, on the App's settings
   page:
   - Note the **App ID** (top of the page).
   - Click **Generate a private key** → downloads a `.pem` file.
9. Click **Install App** (left sidebar) → install on the awfy
   fork only (*Only select repositories* → `<owner>/awfy`).

Encode the private key for Terraform:

```bash
base64 -i ~/Downloads/awfy-bench-runners.*.pem | pbcopy   # macOS
# Linux: base64 -w0 awfy-bench-runners.*.pem | xclip -selection clipboard
```

#### 2.2. Bake the runner AMIs

The Terraform module's `ami_filter` expects custom AMIs whose
names match the patterns `awfy-bench-linux-x86_64-*`,
`awfy-bench-linux-arm64-*`, and `awfy-bench-windows-*`. The
custom AMI is what gives us a quiescent host: `irqbalance` off,
`cpufreq` set to `performance`, no unattended-upgrades, etc. See
`CLOUD_BENCH_PLAN.md` § AMI bake for the full list of tunings.

The bake is a separate, infrequent step — re-run it once a quarter
to pick up base-image security updates, or after editing the
quiescence script. Until you have the AMIs, `terraform apply` will
plan correctly but the Lambda will fail to launch instances
(visible in CloudWatch logs).

For the initial bring-up, you can comment out the `ami_owners` /
`ami_filter` blocks in `terraform/main.tf` and let the module pick
the latest Amazon Linux 2023 / Windows Server 2022 AMI. Numbers
won't be apples-to-apples with later runs once you bake your own
AMI, so re-baseline the trend lines after the bake by deleting the
relevant `_pages/<run-id>/` dirs and re-triggering `bench`.

#### 2.3. Configure and apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region            = "us-east-1"
vpc_id                = "vpc-xxxxxxxx"
subnet_ids            = ["subnet-aaaa", "subnet-bbbb"]
github_app_id         = "<App ID from 2.1>"
github_app_key_base64 = "<base64-encoded .pem from 2.1>"
github_webhook_secret = "<the openssl rand value from 2.1>"

# Cost guardrails (defaults shown; bump budget before a backfill)
monthly_budget_usd             = 25
budget_alert_emails            = ["you@example.com"]
runners_maximum_count_per_pool = 8
```

Two things matter for keeping the bill bounded — both are wired
automatically by `terraform/main.tf`:

- **`runners_maximum_count_per_pool`** caps how many ephemeral
  EC2 instances each pool can have running at once (default 8).
  A typical sweep queues at most 8 jobs per pool, so 8 is the
  steady-state ceiling; a stuck workflow that keeps queueing
  jobs will pile up against this cap rather than spiral.
- **`monthly_budget_usd`** sets an account-wide AWS Budget. Email
  alerts fire at 50% / 80% / 100% of the limit plus a forecast
  alert. **Email-only** — no auto-shutdown. If the bill crosses
  100% the operator decides what to do (typically:
  `terraform destroy` to stop the bleeding, then debug). Default
  $25/mo is ~10× the daily-cron projection; bump before kicking
  off a 40-version backfill (~$24 in EC2 alone). Always USD —
  AWS Budgets has no euro option even when the AWS account is
  invoiced in EUR; AWS converts the USD figures to euros on the
  monthly bill. Pick the USD number you'd be comfortable with on
  the invoice after FX conversion.

If you don't supply `budget_alert_emails`, the budget is still
created (so you can see it in the console) but no notifications
fire. Strongly recommended: set at least one address.

Apply:

```bash
terraform init
terraform apply
```

Save two outputs:

- `webhook_endpoint` — the URL the GitHub App should POST to.
- `runner_labels` — the `runs-on` labels each pool emits. The
  workflow already references these directly; this is just a
  sanity check that they match.

#### 2.4. Wire the webhook back to GitHub

Take the `webhook_endpoint` from `terraform output` and paste it
into the GitHub App's **Webhook URL** field (App settings →
Webhook). Save. GitHub immediately POSTs a `ping` event; you can
verify delivery on the App's *Advanced* tab.

#### 2.5. Verify the wiring

Trigger the cloud workflow once:

```bash
gh workflow run bench --ref master -f otp_refs=master
```

Within ~30 s, the philips-labs Lambda should pick up the
`workflow_job queued` webhook and launch one EC2 instance per
queued job. Watch:

- AWS Console → EC2 → Instances (filter: tag `ghr:Application =
  awfy-bench-linux-x86_64`).
- GitHub → repo → Settings → Actions → Runners — short-lived
  entries appear and disappear as instances register and shut
  down.
- CloudWatch → Log groups → `/aws/lambda/awfy-bench-*` for any
  failure stack traces.

A clean run produces one instance per measure job, each living
~5–10 minutes.

### Per-sweep cost (raw EC2 + Lambda overhead, us-east-1)

| Job | Instance | Wall | Rate | Cost |
|-----|----------|------|------|------|
| `measure-linux x86_64 jit/emu` | c6i.4xlarge | ~5 min × 2 | $0.68/h | ~$0.11 |
| `measure-linux arm64 jit/emu`  | c7g.4xlarge | ~5 min × 2 | $0.58/h | ~$0.10 |
| `measure-windows jit`          | c6i.4xlarge + Win | ~7 min | $0.86/h | ~$0.10 |
| `measure-linux-target` (legacy OTP, both archs/flavors) | c6i/c7g.4xlarge | ~7 min × 4 | ~$0.63/h | ~$0.30 |

Lambda + control-plane overhead is < $0.01/sweep. Total per full
sweep including legacy OTPs: **~$0.61**. Annualised:

| Cadence | Cost |
|---------|------|
| Weekly cron only | ~$32/yr |
| Per-perf-relevant-commit (~200/yr) | ~$122/yr |
| Daily | ~$220/yr |

EU regions price these instance types ~7–15% higher than
`us-east-1` — multiply each row by ~1.10 for `eu-west-1`, ~1.15
for `eu-central-1`. Bump `monthly_budget_usd` accordingly if you
deploy in Europe (still in USD; see § 2.3).

See `CLOUD_BENCH_PLAN.md` § Cost per sweep for the methodology
behind these numbers.

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
adding it to the runner pool.

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
3. Watch `measure-linux` jobs queue and run on the ephemeral
   runner pools — first run will be slow (cold AMI boot + cold
   layer cache, ~15 min total). Subsequent runs reuse the GHA
   layer cache; AMI boot is always cold (ephemeral by design).
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

About 40 sweeps total (~$24 on AWS, ~7 hours of M5 time on the
macOS side via `mix awfy.fill`). After backfill the weekly cron
keeps the recent feature releases current; new patch tags are
benchmarked one-off via additional `workflow_dispatch` triggers.
See `CLOUD_BENCH_PLAN.md` § Backfill and steady-state cadence.

For a no-AWS dry run of the wiring, use the parallel
`bench-test.yml` workflow — it runs the same matrix on
GHA-hosted runners (free, noisy timings). See
`CLOUD_BENCH_PLAN.md` § Phase 0 for what it does and doesn't
validate.
