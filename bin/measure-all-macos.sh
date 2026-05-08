#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# bin/measure-all-macos.sh — run `mix awfy.measure` across every OTP
# ref in the matrix on local macOS-arm64 hardware. Mirrors what the
# measure-macos and measure-macos-target legs do in bench.yml, but
# driven from a single weekend script instead of the GHA matrix.
#
# Usage:
#   bin/measure-all-macos.sh [--refs OTP-28.5,master,...] [--flavors jit,emu] [--build-only]
#
# `--build-only` builds every OTP prefix + target bundle but skips
# `mix awfy.measure`. Useful for pre-warming during a workweek so
# the actual benchmark run on the weekend hits cached prefixes
# (build is the slow part — 5–10 min per ref × ~30 refs).
#
# By default runs every ref `bin/expand-otp-refs.sh all` produces
# (~30 refs covering OTP-20 through master) at both jit and emu
# flavors where applicable. Legacy refs (<24) are emu-only — JIT
# didn't exist before OTP-24.
#
# For each (ref, flavor) the script:
#   * Builds OTP via bin/install-otp-source-mac.sh (idempotent —
#     the install script's OTP_INSTALLED guard short-circuits on
#     repeat invocations).
#   * Modern path (≥24): sets PATH to the OTP prefix and runs
#     `mix awfy.measure` directly. emu flavor sets ERL_FLAGS=+JMsingle
#     false to disable the JIT for a clean emu measurement.
#   * Legacy path (<24): builds a target-Elixir bundle for the OTP
#     prefix (cached per OTP major), sets AWFY_TARGET_ERL /
#     AWFY_TARGET_BUNDLE / AWFY_TARGET_BEAMS, and runs
#     `mix awfy.measure`. The host BencheeRunner dispatches to the
#     bundle target automatically when AWFY_TARGET_ERL is set.
#
# Run-dir naming matches what the publish job expects on gh-pages:
# `<TS>_otp<major>_elixir<ver>_<sha10>-test-macos-arm64-<flavor>`.
# Resumable: skips refs whose run-dir already exists for that
# (sha10, flavor) under results/.
#
# Whole-matrix wallclock on M1: ~1-3 hours per flavor, dominated by
# the per-ref OTP source build the first time (cached afterwards).
# A weekend run is comfortable.
#
# After completion, push to gh-pages with:
#   git fetch origin gh-pages
#   git worktree add /tmp/pages origin/gh-pages
#   cp -r results/2026* /tmp/pages/
#   cd /tmp/pages
#   mix awfy.compare --out .
#   git add -A && git commit -m "macos local fill" && git push origin HEAD:gh-pages
#   git worktree remove /tmp/pages

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT_ROOT"

REFS=""
FLAVORS="jit,emu"
BUILD_ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --refs)       REFS="$2"; shift 2 ;;
    --flavors)    FLAVORS="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    -h|--help)
      sed -n '/^#/p' "$0" | head -55
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REFS" ]; then
  REFS=$(bin/expand-otp-refs.sh all | tr ',' '\n')
else
  REFS=$(echo "$REFS" | tr ',' '\n')
fi

# Per-major Elixir pin for the legacy bundle path (matches bench.yml).
elixir_for_major() {
  case "$1" in
    20) echo "1.9.4"  ;;
    21) echo "1.11.4" ;;
    22) echo "1.13.4" ;;
    23) echo "1.14.5" ;;
    *)  echo ""       ;;
  esac
}

ref_major() {
  case "$1" in
    OTP-*)        echo "${1#OTP-}" | cut -d. -f1 ;;
    master|maint) echo 99 ;;
    *)            echo "$1" | cut -d. -f1 ;;
  esac
}

resolve_sha10() {
  local ref="$1" sha
  case "$ref" in
    master|maint)
      sha=$(git ls-remote https://github.com/erlang/otp.git "refs/heads/$ref" | cut -f1) ;;
    *)
      sha=$(git ls-remote https://github.com/erlang/otp.git "$ref^{}" | head -1 | cut -f1)
      [ -z "$sha" ] && sha=$(git ls-remote https://github.com/erlang/otp.git "$ref" | head -1 | cut -f1) ;;
  esac
  echo "${sha:0:10}"
}

already_measured() {
  local sha10="$1" flavor="$2"
  find results -maxdepth 1 -type d -name "*_${sha10}-test-macos-arm64-${flavor}" 2>/dev/null | head -1
}

run_modern() {
  local ref="$1" prefix="$2" sha10="$3" flavor="$4"
  local existing
  existing=$(already_measured "$sha10" "$flavor")
  if [ -n "$existing" ]; then
    echo "  skip [$flavor]: $existing"
    return 0
  fi
  echo "  measure [$flavor]"
  (
    export PATH="$prefix/bin:$PATH"
    # +JMsingle false disables the JIT in OTP ≥24 → forces the
    # interpreter so we get an apples-to-apples emu measurement
    # even on a JIT-capable runtime.
    if [ "$flavor" = "emu" ]; then
      export ERL_FLAGS="+JMsingle false"
    else
      unset ERL_FLAGS
    fi
    mix deps.get >/dev/null
    mix compile >/dev/null
    mix awfy.measure --label "${sha10}-test-macos-arm64-${flavor}" --ignore-preflight
  )
}

run_legacy() {
  local ref="$1" prefix="$2" sha10="$3" major="$4"
  local flavor="emu"
  local existing
  existing=$(already_measured "$sha10" "$flavor")
  if [ -n "$existing" ]; then
    echo "  skip [emu, legacy]: $existing"
    return 0
  fi
  local elixir_ver
  elixir_ver=$(elixir_for_major "$major")
  if [ -z "$elixir_ver" ]; then
    echo "  error: no Elixir pin for OTP $major" >&2
    return 1
  fi
  local bundle_tar="$PROJECT_ROOT/target_bundle_${elixir_ver}.tar.gz"
  if [ ! -f "$bundle_tar" ]; then
    echo "  building target bundle for Elixir $elixir_ver"
    bin/build-target-bundle.sh "$prefix" "$elixir_ver" "$bundle_tar"
  fi
  local bundle_dir
  bundle_dir=$(mktemp -d -t awfy-bundle-XXXXXX)
  trap 'rm -rf "$bundle_dir"' EXIT
  tar xzf "$bundle_tar" -C "$bundle_dir" --strip-components=1
  echo "  measure [emu, legacy via bundle]"
  (
    export AWFY_TARGET_ERL="$prefix/bin/erl"
    export AWFY_TARGET_BUNDLE="$bundle_dir"
    export AWFY_TARGET_BEAMS="$prefix/awfy_target/awfy-0.1.0/ebin:$prefix/awfy_target/otp_benchmarks-0.1.0/ebin"
    mix awfy.measure --label "${sha10}-test-macos-arm64-emu" --ignore-preflight
  )
  rm -rf "$bundle_dir"
  trap - EXIT
}

echo "[measure-all-macos] refs:"
# shellcheck disable=SC2086 # intentional word-splitting on whitespace.
printf '  %s\n' $REFS
echo "[measure-all-macos] flavors: $FLAVORS"
[ -n "$BUILD_ONLY" ] && echo "[measure-all-macos] --build-only: skipping mix awfy.measure"

for ref in $REFS; do
  echo
  echo "=== $ref ==="
  major=$(ref_major "$ref")
  sha10=$(resolve_sha10 "$ref")
  echo "  major=$major sha10=$sha10"

  prefix=$(bin/install-otp-source-mac.sh "$ref")
  echo "  prefix=$prefix"

  # Pre-warm the legacy bundle too so a `--build-only` pass leaves
  # nothing slow for the weekend measurement run. Modern path
  # doesn't need a bundle.
  if [ "$major" -lt 24 ] && [ "$major" != "99" ]; then
    elixir_ver=$(elixir_for_major "$major")
    if [ -n "$elixir_ver" ]; then
      bundle_tar="$PROJECT_ROOT/target_bundle_${elixir_ver}.tar.gz"
      if [ ! -f "$bundle_tar" ]; then
        echo "  pre-building target bundle for Elixir $elixir_ver"
        bin/build-target-bundle.sh "$prefix" "$elixir_ver" "$bundle_tar"
      fi
    fi
  fi

  if [ -n "$BUILD_ONLY" ]; then
    continue
  fi

  if [ "$major" -ge 24 ] || [ "$major" = "99" ]; then
    for flavor in $(echo "$FLAVORS" | tr ',' ' '); do
      run_modern "$ref" "$prefix" "$sha10" "$flavor"
    done
  else
    run_legacy "$ref" "$prefix" "$sha10" "$major"
  fi
done

echo
echo "[measure-all-macos] all done. results/ contents:"
find results -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -20
echo
echo "Push to gh-pages:"
echo "  git fetch origin gh-pages"
echo "  git worktree add /tmp/pages origin/gh-pages"
echo "  cp -r results/* /tmp/pages/"
echo "  cd /tmp/pages && git add -A && git commit -m 'macos local fill' && git push origin HEAD:gh-pages"
echo "  cd $PROJECT_ROOT && git worktree remove /tmp/pages"
