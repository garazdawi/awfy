#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Resolve the Elixir version paired with a given OTP major. Single
# source of truth — `bench.yml`'s "Pin Elixir version" steps,
# `bin/install-otp-source-mac.sh`'s post-build Elixir install, and
# any future caller all read from here.
#
# Legacy mapping (≤23): the last Elixir release that supports that
# OTP — what the standalone Elixir bundle on gh-pages-trail and
# bin/build-target-bundle.sh expect for legacy targets.
#
# Modern (≥24): 1.19.5 — matches the orchestrator pin in bench.yml's
# erlef/setup-beam@v1 step. Bumping the modern Elixir version here
# is the single edit needed to advance every measurement leg.
#
# Usage:
#   bin/elixir-for-otp.sh <otp_major>
#
# Examples:
#   bin/elixir-for-otp.sh 22         # → 1.13.4
#   bin/elixir-for-otp.sh 28         # → 1.19.5
#   bin/elixir-for-otp.sh master     # → 1.19.5
#   bin/elixir-for-otp.sh maint-25   # → 1.19.5  (anything non-numeric falls through to modern)

set -euo pipefail

OTP_MAJOR="${1:-}"
[ -n "$OTP_MAJOR" ] || { echo "usage: $0 <otp_major>" >&2; exit 2; }

case "$OTP_MAJOR" in
  20) echo "1.9.4"  ;;
  21) echo "1.11.4" ;;
  22) echo "1.13.4" ;;
  23) echo "1.14.5" ;;
  # Modern OTP (≥24) and any non-numeric (master, maint, maint-NN)
  # fall through to the same Elixir as the orchestrator.
  *)  echo "1.19.5" ;;
esac
