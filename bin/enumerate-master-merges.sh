#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Enumerate merge commits that have landed on erlang/otp `master`
# since a baseline ref (default: OTP-29.0). Emits one full SHA per
# line in chronological order (oldest first), so the dashboard's
# trend axis populates left-to-right when each SHA becomes a row in
# the measure matrix.
#
# Usage:
#   ./bin/enumerate-master-merges.sh [<since-ref>]
#
# Arguments:
#   since-ref   — git ref to use as the lower bound. Defaults to
#                 OTP-29.0, the release where master-merge tracking
#                 started for the AWFY dashboard.
#
# Environment:
#   AWFY_MERGES_SINCE_DATE — optional, e.g. "3 months ago". When
#                            set, narrows the output to merges whose
#                            commit date is also newer than this
#                            git-parseable date. The effective lower
#                            bound is `max(<since-ref>, <date>)`, so
#                            an old since-ref + recent date gives a
#                            rolling window.
#
# Output:
#   stdout      — one 40-char SHA per line.
#   stderr      — progress diagnostics + cache notes.
#
# Why merge commits only:
#   PRs land on erlang/otp's `master` via merge commits, and each
#   merge is the natural "feature shipped" boundary. Individual
#   commits within a feature branch represent in-flight work that
#   shouldn't be measured separately — we want one data point per
#   merge so the dashboard's master timeline reflects landed
#   features rather than every typo fix. `--first-parent` keeps us
#   to master's spine, ignoring the side-branch commits each merge
#   pulled in. `--merges` keeps only the merge commits themselves.
#
# Caching:
#   We maintain a `--filter=blob:none --no-checkout` mirror of
#   erlang/otp under `${XDG_CACHE_HOME:-$HOME/.cache}/awfy/otp-mirror`.
#   Subsequent invocations `git fetch` instead of re-cloning. Empty
#   cache → ~30s clone; warm cache → ~5s fetch. Blobless clones
#   skip file contents (only commits + trees are pulled), so disk
#   footprint stays ~50MB even with full master history.

set -euo pipefail

SINCE_REF="${1:-OTP-29.0}"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/awfy"
MIRROR="$CACHE_ROOT/otp-mirror"

mkdir -p "$CACHE_ROOT"

if [ ! -d "$MIRROR/.git" ]; then
  echo "[enumerate-master-merges] clone $MIRROR (first run)" >&2
  # `--filter=blob:none` keeps the clone fast (~5 s instead of ~5
  # min for full history) — we only need commit graph + trees, never
  # blob contents. `--no-checkout` skips writing the working tree
  # to disk; we operate on refs only via `git -C`.
  git clone --filter=blob:none --no-checkout \
    https://github.com/erlang/otp.git "$MIRROR" >&2
else
  echo "[enumerate-master-merges] fetch $MIRROR" >&2
  git -C "$MIRROR" fetch --tags --filter=blob:none origin master >&2
fi

# Confirm the baseline ref is reachable. A typo or stale mirror
# would otherwise produce an empty list silently.
if ! git -C "$MIRROR" rev-parse --verify --quiet "$SINCE_REF" >/dev/null; then
  # Tags sometimes only appear on fetch with --tags; try once more.
  git -C "$MIRROR" fetch --tags origin "$SINCE_REF" >&2 || true
  if ! git -C "$MIRROR" rev-parse --verify --quiet "$SINCE_REF" >/dev/null; then
    echo "[enumerate-master-merges] could not resolve $SINCE_REF on the mirror" >&2
    exit 1
  fi
fi

# `--reverse` flips the default newest-first ordering so the
# dashboard's category axis sorts left-to-right by commit time —
# matches the convention `sort -V` gives the maint-tip enumeration
# in bin/expand-otp-refs.sh.
SINCE_DATE_OPT=()
if [ -n "${AWFY_MERGES_SINCE_DATE:-}" ]; then
  SINCE_DATE_OPT=("--since=$AWFY_MERGES_SINCE_DATE")
fi

shas="$(git -C "$MIRROR" log \
  --merges \
  --first-parent \
  --reverse \
  --format='%H' \
  "${SINCE_DATE_OPT[@]}" \
  "${SINCE_REF}..origin/master")"

if [ -z "$shas" ]; then
  echo "[enumerate-master-merges] no merges between $SINCE_REF and origin/master${AWFY_MERGES_SINCE_DATE:+ (since $AWFY_MERGES_SINCE_DATE)}" >&2
  exit 0
fi

count="$(echo "$shas" | wc -l | xargs)"
echo "[enumerate-master-merges] $count merges since $SINCE_REF${AWFY_MERGES_SINCE_DATE:+ (capped at \"$AWFY_MERGES_SINCE_DATE\")}" >&2
echo "$shas"
