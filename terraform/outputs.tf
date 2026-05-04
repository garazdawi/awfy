# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

output "webhook_endpoint" {
  description = "GitHub webhook URL — paste into the GitHub App's webhook config so workflow_job events reach the runner-spawning Lambda."
  value       = module.runners_linux_x86_64.webhook.endpoint
}

output "runner_labels" {
  description = "GitHub Actions `runs-on` labels emitted by each pool. The bench workflow uses these directly."
  value = {
    linux_x86_64 = ["self-hosted", "awfy-bench-linux-x86_64"]
    linux_arm64  = ["self-hosted", "awfy-bench-linux-arm64"]
    windows      = ["self-hosted", "awfy-bench-windows"]
  }
}
