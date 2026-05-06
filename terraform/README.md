<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# Terraform — ephemeral GitHub Actions runners

This module provisions three ephemeral self-hosted GitHub Actions
runner pools on AWS EC2, one per platform the cloud bench workflow
targets:

| Pool | Instance | Label |
|------|----------|-------|
| `awfy-bench-linux-x86_64` | `c6i.4xlarge` | `awfy-bench-linux-x86_64` |
| `awfy-bench-linux-arm64`  | `c7g.4xlarge` | `awfy-bench-linux-arm64`  |
| `awfy-bench-windows`      | `c6i.4xlarge` + Windows | `awfy-bench-windows` |

It wraps the [`philips-labs/terraform-aws-github-runner`][module]
module — a Lambda watches GitHub for `workflow_job` queued events,
spins up a fresh EC2 instance, the runner registers as ephemeral
(one-shot), runs the job, and the instance terminates. Per-second
billing on raw EC2.

[module]: https://github.com/philips-labs/terraform-aws-github-runner

## AMI selection — Ubuntu LTS, not Amazon Linux

Linux pools run **Ubuntu LTS** (22.04 or 24.04, version-pinned in
`main.tf`'s AMI lookup). The choice is deliberate, see
`PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` § AWS runner pool specifics:

* The `Dockerfile.linux` base is `debian:bullseye-slim`. Ubuntu LTS
  shares glibc and OpenSSL 1.1 with bullseye, so the OTP binary
  built today (and the bundle's Linux-built BEAM bytecode) runs on
  the AWS host unchanged — no Dockerfile rewrite, no `apt → dnf`
  swap, no hand-rolled OpenSSL 1.1 for pre-23 OTP.
* GHA-hosted runners are also Ubuntu. Matching the AWS AMI to that
  means the only difference between `runner_pool=gha` and
  `runner_pool=aws` measurements is the hardware. Switching to
  Amazon Linux would introduce a kernel-tuning / userspace
  divergence that confounds the GHA→AWS handoff.
* AWS supports Ubuntu as a first-class AMI (Canonical-published, no
  extra cost vs Amazon Linux). LTS support is 5+5 years.

When pinning the AMI, prefer the `ami-name` filter over a fixed
`ami-id` so weekly Canonical security patches roll forward without
a Terraform apply. See `main.tf`'s `data.aws_ami.ubuntu` block.

## Bundle distribution — S3 (optional)

The Phase-2 `prep-target-bundle` workflow job uploads each
target-Elixir bundle as a GHA artifact and (when
`runner_pool=aws`) also pushes a copy to S3 for the AWS measure
jobs. The bucket name comes from a workflow var
`AWFY_TARGET_BUNDLE_S3_BUCKET` (set under Repository Settings →
Variables); leave it empty to skip the S3 step entirely.

Bucket sizing: ~600 MB across the 4 pinned Elixir bundles
(20 → 1.9.4, 21 → 1.11.4, 22 → 1.13.4, 23 → 1.14.5);
~$0.014/month at us-east-1 standard pricing.

## Quick start

```bash
# Once per machine
brew install terraform   # or: tfenv install latest && tfenv use latest

# Once per repo
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your VPC, subnet, GitHub App credentials

# Apply
cd terraform
terraform init
terraform apply
```

Full operator walkthrough — including AMI bake, GitHub App
creation, and webhook wiring — lives in `SETUP.md` § 2.

## State

Local state by default. Move to S3 + DynamoDB by uncommenting the
`backend "s3" { ... }` block in `main.tf` once you want a remote
audit trail or a second operator.

The state file contains the GitHub App private key (decoded from
`github_app_key_base64`). `terraform.tfstate` is `.gitignore`'d
already; treat it like a secret on disk.

## Cost guardrails

Two layers — both enabled by default, both tunable in
`terraform.tfvars`:

- `runners_maximum_count_per_pool` (default 8) caps concurrent
  ephemeral runners per pool. Steady-state ceiling — a stuck
  workflow piles up against this rather than spiralling.
- `monthly_budget_usd` (default $25) sets an account-wide AWS
  Budget. Email alerts at 50% / 80% / 100% plus a forecast
  alert. **Email-only** — no auto-shutdown. If you breach 100%,
  decide what to do manually (typically `terraform destroy`).
  Set `budget_alert_emails = ["you@example.com"]` to actually
  receive the notifications.

Bump the budget *before* a 40-version backfill (~$24 in EC2 alone
on top of normal cron spend); otherwise the forecast alert will
fire mid-backfill.

## Drift / drift detection

Re-apply once a quarter to catch upstream module updates:

```bash
terraform init -upgrade
terraform plan
terraform apply
```

Pin a specific module version (`version = "~> 6.0"`) so unrelated
upstream changes don't surprise you between applies.
