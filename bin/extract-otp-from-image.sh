#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Extract the OTP install and target benchmark beams from a
# per-OTP-SHA `build-linux` Docker image onto the host, no
# `docker run` involved. Used by:
#   * `prep-target-bundle` — feeds the OTP install dir to
#     `bin/build-target-bundle.sh` so `prep` doesn't duplicate
#     `build-linux`'s OTP source build (PLAN decision #12).
#   * AWS measure jobs — extract once per workflow run, then invoke
#     `./otp/bin/erl` directly on the host (bare-metal exec, no
#     container around the benchmark) per
#     PLAN/TARGET_ELIXIR_RUNNER_PLAN.md § AWS runner pool specifics.
#
# The Dockerfile.linux build stage installs OTP at /usr/local and
# the target benchmark beams at /opt/awfy_target/awfy-0.1.0/. Both
# get pulled out and merged under <output_dir>/ so the host sees a
# single tree:
#   <output_dir>/bin/erl
#   <output_dir>/lib/erlang/...
#   <output_dir>/awfy_target/awfy-0.1.0/{ebin,priv}/   (target benchmarks)
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

echo "[extract-otp] copying /usr/local + /opt/awfy_target → $OUTPUT" >&2
TMP="$(mktemp -d)"

# OTP install — `/usr/local/{bin,lib,share,...}`. We want bin/ and
# lib/erlang at the top level of $OUTPUT. The /usr/local tree also
# has the precompiled Elixir bundle the modern image ships; that
# tags along harmlessly.
docker cp "$ID":/usr/local "$TMP/usr_local"

# Target benchmark beams — only present on legacy images
# (build-linux-target). Modern images don't include them; the
# `|| true` keeps the script useful for both.
docker cp "$ID":/opt/awfy_target "$TMP/awfy_target" 2>/dev/null \
  || echo "[extract-otp] no /opt/awfy_target in image (modern path) — skipping" >&2

mkdir -p "$OUTPUT"
cp -R "$TMP/usr_local/." "$OUTPUT/"
if [ -d "$TMP/awfy_target" ]; then
  cp -R "$TMP/awfy_target" "$OUTPUT/awfy_target"
fi
rm -rf "$TMP"

[ -x "$OUTPUT/bin/erl" ] || {
  echo "[extract-otp] expected $OUTPUT/bin/erl after extract" >&2
  exit 1
}

ABS="$(cd "$OUTPUT" && pwd)"
echo "[extract-otp] OTP at $ABS" >&2
echo "$ABS"
