# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  description = "AWS region. Pick one that has both c6i and c7g (Graviton 3) capacity — us-east-1, us-west-2, eu-west-1 all qualify."
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "Existing VPC ID to launch runners in. The default VPC works for a single-account setup; create a dedicated one if you want network-level isolation from the rest of the account."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for runner instances. Use private subnets with a NAT gateway for outbound — runners need internet access to register with GitHub and pull from GHCR. Public subnets work too but expose runners to the public internet."
  type        = list(string)
}

variable "github_app_id" {
  description = "GitHub App ID. Create the App at https://github.com/settings/apps/new with the permissions documented in SETUP.md § 2; the ID is shown on the App's settings page after creation."
  type        = string
}

variable "github_app_key_base64" {
  description = "Base64-encoded GitHub App private key (the .pem GitHub generates after App creation). `base64 -i app.pem | pbcopy` on macOS."
  type        = string
  sensitive   = true
}

variable "github_webhook_secret" {
  description = "Random shared secret for the GitHub webhook. Generate via `openssl rand -hex 32`."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Cost guardrails — see CLOUD_BENCH_PLAN.md § Cost per sweep for context. A
# full sweep is ~$0.61, weekly steady state ~$32/yr, daily ~$220/yr. Anything
# wildly above those numbers is a bug — a stuck cron, a runaway dispatch loop,
# a misconfigured runner that won't shut down. The budget below is the
# emergency brake; the per-pool runner cap is the day-to-day fence.
# -----------------------------------------------------------------------------

variable "monthly_budget_usd" {
  description = "Hard ceiling on monthly AWS spend, account-wide. AWS Budgets fires email alerts at 50% / 80% / 100% of this plus a forecast alert. Default ($25) covers ~10× the daily-cron projection and leaves room for a one-off backfill, but errs low — bump it before kicking off a 40-version backfill on top of an active cron. Always USD: AWS Budgets only supports USD as the limit unit even when your account is billed in another currency (AWS converts on the invoice at month-end). Stay in USD here; just pick the number you'd be comfortable with on the bill after FX conversion (€1 ≈ $1.10 as of 2026, so a $25 cap ≈ €23 on the invoice)."
  type        = number
  default     = 25
}

variable "budget_alert_emails" {
  description = "Email addresses to notify when the monthly budget crosses 50%/80%/100% of `monthly_budget_usd`. Empty = no alerts (still get the budget cap, just no emails). At least one address is strongly recommended."
  type        = list(string)
  default     = []
}

variable "runners_maximum_count_per_pool" {
  description = "Hard cap on concurrent ephemeral runners per pool. A typical sweep queues at most 8 jobs per pool (4 OTP versions × 2 flavors), so 8 is the steady-state ceiling; bumping above that won't speed sweeps up but multiplies the worst-case bill if something goes wrong. Setting too low (e.g. 2) means jobs queue serially and one stuck job stalls everything else."
  type        = number
  default     = 8
}
