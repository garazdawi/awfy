# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

# Terraform-managed ephemeral GitHub Actions runners on AWS EC2.
#
# Three runner pools, each pinned to a specific instance type so the
# benchmark numbers are reproducible across runs and across years:
#
#   - awfy-bench-linux-x86_64  → c6i.4xlarge
#   - awfy-bench-linux-arm64   → c7g.4xlarge (Graviton 3)
#   - awfy-bench-windows       → c6i.4xlarge + Windows
#
# Each pool registers itself with GitHub via a single GitHub App (set
# up once, shared across pools). When a workflow_job event fires for a
# matching `runs-on:` label, the module spins up a fresh EC2 instance,
# the runner registers as ephemeral (one-shot), runs the job, and the
# instance terminates. Per-second billing on raw EC2 — no idle charges.
#
# Quickstart: see terraform/README.md.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
  # Local state is fine for a single operator. Move to S3 + DynamoDB
  # once a second person needs to apply or you want a remote audit
  # trail.
  # backend "s3" { bucket = "..."; key = "awfy/terraform.tfstate"; region = "..."; dynamodb_table = "..." }
}

provider "aws" {
  region = var.aws_region
}

# Shared identifier prefix so resources across the three modules are
# easy to grep for in the AWS console.
locals {
  prefix = "awfy-bench"

  # The App's private key is `sensitive = true` on the variable, so it's
  # redacted from `terraform plan` output, but it does end up in the
  # state file. Treat `terraform.tfstate` like a secret on disk —
  # don't commit it, don't share. Move to an S3 backend with bucket-key
  # encryption when you stop being the only operator.
  github_app = {
    id             = var.github_app_id
    key_base64     = var.github_app_key_base64
    webhook_secret = var.github_webhook_secret
  }
}

# ---------------------------------------------------------------------
# Linux x86_64 — c6i.4xlarge — the primary "publication-quality" pool.
# ---------------------------------------------------------------------
module "runners_linux_x86_64" {
  source  = "philips-labs/github-runner/aws"
  version = "~> 6.0"

  aws_region = var.aws_region
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  prefix = "${local.prefix}-linux-x86_64"

  github_app = local.github_app

  runner_extra_labels = ["awfy-bench-linux-x86_64"]
  enable_ephemeral_runners = true

  instance_types = ["c6i.4xlarge"]
  runner_os      = "linux"
  runner_architecture = "x64"

  # Custom AMI bake includes irqbalance/cpufreq/tmpfs quiescence —
  # see CLOUD_BENCH_PLAN.md § CPU pinning for the bake script.
  ami_owners = ["self"]
  ami_filter = {
    name = ["awfy-bench-linux-x86_64-*"]
  }

  # Idle timeout: kill the instance immediately after the job ends.
  # We don't reuse runners across jobs (ephemeral=true above), so any
  # idle window is wasted spend.
  scale_down_schedule_expression = "cron(* * * * ? *)"

  # Cost guardrails — each runner runs at most this long before being
  # forcibly terminated. Catches stuck jobs without runaway billing.
  runner_boot_time_in_minutes = 5
  runners_maximum_count       = var.runners_maximum_count_per_pool
  runner_run_as = "root"
}

# ---------------------------------------------------------------------
# Linux ARM64 — c7g.4xlarge (Graviton 3). No SMT, vCPU 0 = one core.
# ---------------------------------------------------------------------
module "runners_linux_arm64" {
  source  = "philips-labs/github-runner/aws"
  version = "~> 6.0"

  aws_region = var.aws_region
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  prefix = "${local.prefix}-linux-arm64"

  github_app = local.github_app

  runner_extra_labels = ["awfy-bench-linux-arm64"]
  enable_ephemeral_runners = true

  instance_types = ["c7g.4xlarge"]
  runner_os      = "linux"
  runner_architecture = "arm64"

  ami_owners = ["self"]
  ami_filter = {
    name = ["awfy-bench-linux-arm64-*"]
  }

  scale_down_schedule_expression = "cron(* * * * ? *)"
  runner_boot_time_in_minutes = 5
  runners_maximum_count       = var.runners_maximum_count_per_pool
  runner_run_as = "root"
}

# ---------------------------------------------------------------------
# Windows — c6i.4xlarge with Windows Server 2022. CPU pinning via
# PowerShell ProcessorAffinity inside the workflow.
# ---------------------------------------------------------------------
module "runners_windows" {
  source  = "philips-labs/github-runner/aws"
  version = "~> 6.0"

  aws_region = var.aws_region
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  prefix = "${local.prefix}-windows"

  github_app = local.github_app

  runner_extra_labels = ["awfy-bench-windows"]
  enable_ephemeral_runners = true

  instance_types = ["c6i.4xlarge"]
  runner_os      = "windows"
  runner_architecture = "x64"

  ami_owners = ["self"]
  ami_filter = {
    name = ["awfy-bench-windows-*"]
  }

  scale_down_schedule_expression = "cron(* * * * ? *)"
  runner_boot_time_in_minutes = 5
  runners_maximum_count       = var.runners_maximum_count_per_pool
}

# ---------------------------------------------------------------------
# Cost guardrails — emergency brake.
#
# AWS Budgets is the catch-all if something we didn't anticipate spends
# real money. The per-pool `runners_maximum_count` above caps concurrent
# instances; this caps total monthly spend on the whole AWS account.
# Account-wide (no cost_filter) is intentional: cost-tag-based filters
# don't catch every AWS billing line item (NAT gateway hours, KMS
# requests, CloudWatch ingest, Lambda concurrent execution overage),
# and the operator-account convention here is "this account exists for
# awfy" — anything spending real money in it *is* awfy-related.
#
# Three notifications fire at 50% / 80% / 100% of the configured ceiling
# plus a forecast alert. Email-only — explicit, no automation. If the
# bill ever crosses 100% the operator gets paged and decides what to do
# (typically: run `terraform destroy` to stop the bleeding, then debug).
# Auto-stop is intentionally *not* wired here: a misconfigured action
# could nuke in-flight runs mid-sweep without warning, and we'd rather
# the human decide.
# ---------------------------------------------------------------------
resource "aws_budgets_budget" "awfy_monthly" {
  name         = "${local.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [50, 80, 100] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  # Forecast alert at 100% gives a heads-up before the actual spend hits
  # the cap — typically several days of warning at the weekly-cron rate.
  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [100] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}
