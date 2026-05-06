#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Phase-2 parity check helper. Compares per-benchmark medians
# between the legacy `-target` and new `-target-v2` runs of the
# same OTP ref.
#
# Acceptance (PLAN decision #9):
#   * aggregate geomean delta within ±5% across all benchmarks;
#   * no individual benchmark's |delta| exceeds 15%.
#
# Larger deltas mean the two paths are measuring different things
# and need investigation before Phase 3 lands the dispatch flip.
#
# Usage:
#   bin/compare-target-paths.sh <legacy_run_dir> <bundle_run_dir>
#
# Each run-dir is one produced by `mix awfy.measure` for the same
# OTP ref. The script's stdout is a per-benchmark table plus the
# aggregate geomean delta and a pass/fail verdict.
#
# Implementation runs under the host's Elixir/Mix because we already
# have `Awfy.Compare.Data.load/1` to parse `.benchee` files; no need
# to reinvent the loader in shell.

set -euo pipefail

usage() {
  echo "usage: $0 <legacy_run_dir> <bundle_run_dir>" >&2
  echo "  Compare per-benchmark medians between legacy -target and" >&2
  echo "  new -target-v2 runs of the same OTP ref." >&2
  exit 2
}

LEGACY="${1:-}"
BUNDLE="${2:-}"
[ -n "$LEGACY" ] || usage
[ -n "$BUNDLE" ] || usage
[ -d "$LEGACY" ] || { echo "[compare] not a dir: $LEGACY" >&2; exit 1; }
[ -d "$BUNDLE" ] || { echo "[compare] not a dir: $BUNDLE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWFY_ROOT="$(dirname "$SCRIPT_DIR")"

# The Elixir snippet that does the actual comparison lives at
# `priv/compare_target_paths.exs`. We pass the two run-dirs through
# env vars (avoids escaping nightmares interpolating shell vars
# into a quoted Elixir string) and let `mix run` execute the
# script. Mix.raise → non-zero exit propagates parity failures back
# to the caller.
cd "$AWFY_ROOT"
exec env \
  AWFY_COMPARE_LEGACY="$LEGACY" \
  AWFY_COMPARE_BUNDLE="$BUNDLE" \
  mix run --no-start priv/compare_target_paths.exs
