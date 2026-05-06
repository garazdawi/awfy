#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Extract `/opt/otp` from a per-OTP-SHA `build-linux` Docker image
# onto the host, no `docker run` involved. Used by:
#   * `prep-target-bundle` — feeds the OTP install dir to
#     `bin/build-target-bundle.sh` so `prep` doesn't duplicate
#     `build-linux`'s OTP source build (PLAN decision #12).
#   * AWS measure jobs — extract once per workflow run, then invoke
#     `./otp/bin/erl` directly on the host (bare-metal exec, no
#     container around the benchmark) per
#     PLAN/TARGET_ELIXIR_RUNNER_PLAN.md § AWS runner pool specifics.
#
# Mechanics (PLAN decision #6): docker create + docker cp + docker rm.
# Doesn't require `docker run`, doesn't restructure Dockerfile.linux,
# leaves no stopped containers behind.
#
# Usage:
#   bin/extract-otp-from-image.sh <image> [<output_dir>]
#
# Defaults:
#   output_dir = ./otp
#
# Idempotent: if $output_dir/bin/erl is already executable, the
# script exits 0 without re-extracting (the cache invalidation is
# the image SHA — caller is expected to bump the image tag when
# the OTP source changes).

set -euo pipefail

usage() {
  echo "usage: $0 <image> [<output_dir>]" >&2
  echo "  e.g. $0 ghcr.io/lhc/awfy:abc1234-x86_64 ./otp" >&2
  exit 2
}

IMAGE="${1:-}"
OUTPUT="${2:-./otp}"
[ -n "$IMAGE" ] || usage

if [ -x "$OUTPUT/bin/erl" ]; then
  echo "[extract-otp] $OUTPUT/bin/erl already present — skipping" >&2
  echo "$OUTPUT"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"

echo "[extract-otp] creating throwaway container from $IMAGE" >&2
ID="$(docker create "$IMAGE")"

# Always tear down the container, even on cp failure.
trap 'docker rm "$ID" >/dev/null 2>&1 || true' EXIT

echo "[extract-otp] copying /opt/otp → $OUTPUT" >&2
# `docker cp <id>:/opt/otp <dst>` writes to <dst>/otp/ when <dst> is
# a directory. Cope with both "OUTPUT exists" and "OUTPUT is the
# requested final path" by copying contents-of-/opt/otp into OUTPUT.
TMP="$(mktemp -d)"
docker cp "$ID":/opt/otp "$TMP/otp"

# Move into place atomically (within the same fs) for predictable
# cache-hit behaviour on re-run.
mkdir -p "$OUTPUT"
# `cp -R src/. dst/` copies contents-of-src into dst.
cp -R "$TMP/otp/." "$OUTPUT/"
rm -rf "$TMP"

[ -x "$OUTPUT/bin/erl" ] || {
  echo "[extract-otp] expected $OUTPUT/bin/erl after extract" >&2
  exit 1
}

ABS="$(cd "$OUTPUT" && pwd)"
echo "[extract-otp] OTP at $ABS" >&2
echo "$ABS"
