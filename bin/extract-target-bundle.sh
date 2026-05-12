#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Extract a target-Elixir bundle tarball into a directory and assert
# the canonical TargetRunner beam landed where Awfy.Runner expects.
# Used by both legacy-measure jobs (measure-linux-target,
# measure-macos-target) to share one extraction + validation path.
#
# Usage:
#   bin/extract-target-bundle.sh <tarball.tar.gz> <output-dir>
#
# Without the post-extract assertion, a layout mismatch lets every
# benchmark abort with `undef Elixir.Awfy.TargetRunner` while the
# job stays green (errors are caught per-scenario in BencheeRunner).
# Failing here turns that into a visible step failure.

set -euo pipefail

TARBALL="${1:?usage: $0 <tarball.tar.gz> <output-dir>}"
OUTDIR="${2:?usage: $0 <tarball.tar.gz> <output-dir>}"

mkdir -p "$OUTDIR"
tar xzf "$TARBALL" -C "$OUTDIR" --strip-components=1

echo "[extract] $OUTDIR/ top-level entries:"
# shellcheck disable=SC2012  # human-readable display; non-alphanumeric
# filenames in a bundle would be a bigger problem than ls's handling.
ls -la "$OUTDIR/" | head -20
echo "[extract] $OUTDIR/lib/ entries:"
# shellcheck disable=SC2012
ls -la "$OUTDIR/lib/" 2>/dev/null | head -25

RUNNER="$OUTDIR/lib/awfy_target_runner/ebin/Elixir.Awfy.TargetRunner.beam"
if [ ! -f "$RUNNER" ]; then
  echo "::error::bundle extract: runner beam missing at $RUNNER"
  echo "::group::$OUTDIR/ contents (recursive, max-depth 4)"
  find "$OUTDIR" -maxdepth 4 -print
  echo "::endgroup::"
  exit 1
fi
