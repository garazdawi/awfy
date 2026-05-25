#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Print the OTP major version that erlang/otp's `master` branch
# currently tracks (e.g. "29" while master is on the 29.0-rc line,
# "30" once master rolls forward after OTP-29.0 ships). This is the
# next-major-after-the-latest-release; bumps roughly yearly.
#
# Used by:
#   * `Awfy.Fill.Resolve` (lib/awfy/fill/resolve.ex) — labelling `master` runs in fill
#     and as a final fallback when a SHA's OTP_VERSION can't be
#     fetched
#   * .github/workflows/bench.yml — same role in the production
#     cloud workflow's resolve step
#
# Output: a single integer on stdout, no trailing whitespace beyond
# the natural line. Exits non-zero with a diagnostic on stderr if
# the upstream OTP_VERSION can't be fetched — better to fail
# loudly than to silently mislabel runs with a stale hardcoded
# number.
#
# Memoise at the call site (one curl per resolve step is plenty);
# this script always re-fetches.

set -euo pipefail

major="$(
  curl -fsSL https://raw.githubusercontent.com/erlang/otp/master/OTP_VERSION 2>/dev/null \
    | head -1 | cut -d. -f1
)"

if [ -z "$major" ]; then
  echo "[next-master-major] failed to fetch erlang/otp master OTP_VERSION; cannot determine current major" >&2
  exit 1
fi

echo "$major"
