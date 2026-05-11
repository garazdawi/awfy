#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Resolve the Elixir version paired with a given OTP major. Single
# source of truth — `bench.yml`'s "Pin Elixir version" steps,
# `bin/install-otp-source-mac.sh`'s post-build Elixir install,
# `bin/measure-all-macos.sh`'s modern-path PATH wiring, and
# `bin/resolve-fill-needs.sh`'s matrix builder all read from here.
#
# The mapping pins the last Elixir release that supports each OTP
# major, per Elixir's release notes
# (hexdocs.pm/elixir/compatibility-and-deprecations). Going past
# the cap means `mix` won't load on the target — Elixir 1.19, for
# example, dropped OTP < 26, so OTP 24/25 must use 1.16/1.17.
#
# 28+ caps at 1.19.5 — the latest tagged release. Bump this when
# Elixir cuts a release that nominally supports the new OTP.
#
# Usage:
#   bin/elixir-for-otp.sh <otp_major>
#
# Examples:
#   bin/elixir-for-otp.sh 22         # → 1.13.4
#   bin/elixir-for-otp.sh 24         # → 1.16.3
#   bin/elixir-for-otp.sh 28         # → 1.19.5
#   bin/elixir-for-otp.sh master     # → 1.19.5
#   bin/elixir-for-otp.sh maint-25   # → 1.19.5  (non-numeric → latest)

set -euo pipefail

OTP_MAJOR="${1:-}"
[ -n "$OTP_MAJOR" ] || { echo "usage: $0 <otp_major>" >&2; exit 2; }

case "$OTP_MAJOR" in
  20) echo "1.9.4"  ;;
  21) echo "1.11.4" ;;
  22) echo "1.13.4" ;;
  23) echo "1.14.5" ;;
  24) echo "1.16.3" ;;
  25) echo "1.17.3" ;;
  26) echo "1.18.4" ;;
  27) echo "1.19.5" ;;
  # OTP 28+ and any non-numeric (master, maint, maint-NN) → latest.
  *)  echo "1.19.5" ;;
esac
