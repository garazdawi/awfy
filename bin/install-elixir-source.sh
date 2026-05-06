#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Build Elixir from source against a target OTP install. No system
# install — leaves the built tree at $output and prints its absolute
# path. Caller is expected to put $output/bin on PATH or invoke the
# elixir/mix scripts directly.
#
# Usage:
#   bin/install-elixir-source.sh <elixir_version> <otp_prefix> [<output_dir>]
#
# Defaults:
#   output_dir = $HOME/.local/elixir-src/<elixir_version>
#
# Idempotent: if $output_dir/bin/elixir is already executable, exits
# 0 without rebuilding. The script's own cache key is just the
# version + output path; bumping the target OTP without bumping the
# Elixir version reuses the existing build (Elixir's BEAM bytecode is
# OTP-independent at runtime).
#
# Why source-build instead of pulling a precompiled bundle:
#   * elixir-lang/elixir's release artifacts (`elixir-otp-NN.zip`)
#     only cover OTP 24 onwards — exactly the OTPs we don't need
#     this script for. Below that we have no precompiled choice.
#   * Building Elixir from source is fast (~30s per version on a
#     warm checkout); the OTP build dominates wall time anyway.

set -euo pipefail

usage() {
  echo "usage: $0 <elixir_version> <otp_prefix> [<output_dir>]" >&2
  echo "  e.g. $0 1.9.4 /opt/otp ~/.local/elixir-src/1.9.4" >&2
  exit 2
}

ELIXIR_VERSION="${1:-}"
OTP_PREFIX="${2:-}"
OUTPUT_DIR="${3:-$HOME/.local/elixir-src/$ELIXIR_VERSION}"

[ -n "$ELIXIR_VERSION" ] || usage
[ -n "$OTP_PREFIX" ] || usage

[ -x "$OTP_PREFIX/bin/erl" ] || {
  echo "[install-elixir] $OTP_PREFIX is not an OTP install (no bin/erl)" >&2
  exit 1
}

if [ -x "$OUTPUT_DIR/bin/elixir" ]; then
  echo "[install-elixir] cached at $OUTPUT_DIR" >&2
  echo "$OUTPUT_DIR"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT_DIR")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[install-elixir] cloning v$ELIXIR_VERSION" >&2
git clone --depth 1 --branch "v$ELIXIR_VERSION" \
  https://github.com/elixir-lang/elixir.git "$TMP/elixir"

# Elixir's Makefile finds erl via PATH and links its compiled beams
# against whatever ERTS the discovered erl reports. Putting target
# OTP first on PATH guarantees we build against it.
NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null \
  || nproc 2>/dev/null \
  || sysctl -n hw.ncpu 2>/dev/null \
  || echo 2)"

echo "[install-elixir] building Elixir $ELIXIR_VERSION against $OTP_PREFIX (-j$NPROC)" >&2
PATH="$OTP_PREFIX/bin:$PATH" \
  make -C "$TMP/elixir" -j"$NPROC"

mv "$TMP/elixir" "$OUTPUT_DIR"
trap - EXIT

echo "[install-elixir] installed at $OUTPUT_DIR" >&2
echo "$OUTPUT_DIR"
