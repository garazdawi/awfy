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

# Per-major Elixir pin — single source of truth in
# priv/elixir-for-otp.sh, shared with bench.yml and
# install-otp-source-mac.sh. Modern path needs this too: Elixir 1.19
# dropped OTP < 26, so OTP 24/25 boot dies with `undef
# elixir:start_cli/0` if the host's 1.19 is on PATH. Picking the
# per-major version (24→1.16.3, 25→1.17.3, 26→1.18.4, 27+→1.19.5)
# keeps both legs alive.
elixir_for_major() {
  priv/elixir-for-otp.sh "$1"
}

ref_major() {
  case "$1" in
    OTP-*)        echo "${1#OTP-}" | cut -d. -f1 ;;
    master|maint) echo 99 ;;
    *)            echo "$1" | cut -d. -f1 ;;
  esac
}

# Full target OTP version (e.g. "20.3", "24.0.6", "28.5") for
# meta.json's `otp` field via `awfy.measure`'s AWFY_OTP_VERSION env
# (lib/mix/tasks/awfy.measure.ex:455). Without this the legacy
# bundle path's meta.json reports the host's OTP-28.4.1 — runs get
# misplaced on the dashboard's OTP-X axis. Modern path also benefits:
# `System.otp_release/0` only gives the major, so OTP-24.0.6 would
# otherwise show as bare "24" without this. master / maint don't
# have a fixed version — fall back to reading the prefix's
# OTP_VERSION file, which the install script generates at build
# time.
ref_full_version() {
  local ref="$1"
  # Mirror GHA's `otp_label` contract (see resolve-fill-needs.sh): tags
  # collapse to the version, branches pass through verbatim so master /
  # maint land at the right edge of the trend chart and aren't filtered
  # out by the stability page's `r.otp == "master"` check.
  case "$ref" in
    OTP-*)               echo "${ref#OTP-}" ;;
    master|maint|maint-*) echo "$ref" ;;
    *)                   echo "$ref" ;;
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

# Commit committer date for the SHA, ISO 8601 — used by
# AWFY_OTP_COMMIT_TIMESTAMP so the dashboard's trend chart plots
# each macOS measurement against the OTP commit's point in time
# rather than clustering every refill at "today". Mirrors the
# resolve-fill-needs.sh logic for the GHA path. Falls back to
# empty (mix awfy.measure then uses wall-clock — same behaviour
# as before this function existed) if `gh` isn't installed, the
# user isn't logged in, or the API call fails. 10-char SHAs are
# unique enough in erlang/otp for the API to resolve them.
ref_commit_timestamp() {
  local sha10="$1"
  command -v gh >/dev/null 2>&1 || { echo ""; return; }
  gh api "repos/erlang/otp/commits/$sha10" 2>/dev/null \
    | jq -r '.commit.committer.date // ""' 2>/dev/null \
    || echo ""
}

already_measured() {
  local sha10="$1" flavor="$2"
  find results -maxdepth 1 -type d -name "*_${sha10}-test-macos-arm64-${flavor}" 2>/dev/null | head -1
}

run_modern() {
  local ref="$1" prefix="$2" sha10="$3" flavor="$4" major="$5"
  local existing
  existing=$(already_measured "$sha10" "$flavor")
  if [ -n "$existing" ]; then
    echo "  skip [$flavor]: $existing"
    return 0
  fi
  # Pick the target-paired Elixir. install-otp-source-mac.sh has
  # already source-built it against this prefix and cached it at
  # $HOME/.local/elixir-src/<ver>/ via bin/install-elixir-source.sh.
  # Putting that bin/ on PATH ahead of the asdf-managed host Elixir
  # is what makes `mix awfy.measure` find an Elixir that can load
  # under this OTP's emulator — Elixir 1.19's beams won't load on
  # OTP 24/25, the host crashes with `undef elixir:start_cli/0`.
  local elixir_ver elixir_dir
  elixir_ver=$(elixir_for_major "$major")
  elixir_dir="$HOME/.local/elixir-src/$elixir_ver"
  if [ ! -x "$elixir_dir/bin/elixir" ]; then
    echo "  error: target Elixir $elixir_ver not built at $elixir_dir" >&2
    return 1
  fi
  echo "  measure [$flavor] elixir=$elixir_ver"
  (
    export PATH="$prefix/bin:$elixir_dir/bin:$PATH"
    # Force meta.json's `otp` field to the target's full version
    # (e.g. "24.0.6"), not just the host's major from
    # System.otp_release/0 — see awfy.measure.ex's otp_version_label/0.
    local full_ver
    full_ver=$(ref_full_version "$ref")
    # shellcheck disable=SC2030,SC2031  # The exports take effect for
    # the rest of this function — the child `mix awfy.measure` reads
    # them. Shellcheck's subshell heuristic misreads the for-loop +
    # function-call structure these are nested under.
    [ -n "$full_ver" ] && export AWFY_OTP_VERSION="$full_ver"
    # Anchor the dashboard's trend-axis position to the OTP
    # commit's date rather than wall-clock — without this the M5
    # sweep stamps every measurement at "now" and clusters them
    # at the right edge of the trend chart, even when measuring
    # an OTP from years ago. Best-effort: `gh api` may not be
    # configured locally; the helper returns "" and
    # awfy.measure's trend_timestamp/0 falls back to wall-clock.
    local commit_ts
    commit_ts=$(ref_commit_timestamp "$sha10")
    # shellcheck disable=SC2030,SC2031
    [ -n "$commit_ts" ] && export AWFY_OTP_COMMIT_TIMESTAMP="$commit_ts"
    # Pin the Elixir version that ends up in meta.json (modern path
    # uses the per-OTP-major target Elixir on PATH, but
    # System.version/0 reads whatever Elixir the host orchestrator
    # was spawned under — usually the latest). awfy.measure prefers
    # AWFY_TARGET_ELIXIR_VERSION over System.version/0.
    # shellcheck disable=SC2030,SC2031
    export AWFY_TARGET_ELIXIR_VERSION="$elixir_ver"
    # Isolate MIX_HOME so a stale `~/.mix/archives/hex-X.Y.Z` (which
    # was compiled against whatever OTP installed it) doesn't get
    # auto-loaded by the per-major Elixir. Hex 2.4.x in particular
    # crashes on OTP 28 with "Hex.Repo was given as a child to a
    # supervisor but it does not exist" — the archive's compiled
    # bytecode references stdlib modules the new emulator no longer
    # provides at the same arity. The clean MIX_HOME has no archives
    # so mix skips the auto-load and starts cleanly. Same isolation
    # build-target-bundle.sh uses for the legacy bundle build.
    MIX_HOME="$(mktemp -d -t awfy-mix-home-XXXXXX)"
    export MIX_HOME
    trap 'rm -rf "$MIX_HOME"' EXIT
    # +JMsingle false disables the JIT in OTP ≥24 → forces the
    # interpreter so we get an apples-to-apples emu measurement
    # even on a JIT-capable runtime. But OTP builds with
    # `--disable-jit` (e.g. Group B's OTP-25.0/25.1/25.2 with the
    # ARM-W^X workaround) reject the flag with "JIT is not supported
    # on this system (option -JMsingle)" and abort. Probe first;
    # if the flag isn't accepted we're already on the interpreter
    # by virtue of the build, so no flag is needed.
    if [ "$flavor" = "emu" ]; then
      if "$prefix/bin/erl" +JMsingle false -noshell -eval 'halt().' >/dev/null 2>&1; then
        export ERL_FLAGS="+JMsingle false"
      else
        unset ERL_FLAGS
      fi
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
    # meta.json's `otp` field — without this the legacy bundle
    # path reports the host orchestrator's OTP (28.x) and runs
    # cluster at the wrong point on the dashboard's X axis.
    local full_ver
    full_ver=$(ref_full_version "$ref")
    # shellcheck disable=SC2030,SC2031  # subshell-scoped exports are
    # intentional — the `mix awfy.measure` line below runs inside this
    # same subshell so the exports reach it; we *want* them isolated
    # from the outer loop.
    [ -n "$full_ver" ] && export AWFY_OTP_VERSION="$full_ver"
    # Same trend-timestamp anchor as the modern path — see
    # run_modern for the rationale.
    local commit_ts
    commit_ts=$(ref_commit_timestamp "$sha10")
    # shellcheck disable=SC2030,SC2031
    [ -n "$commit_ts" ] && export AWFY_OTP_COMMIT_TIMESTAMP="$commit_ts"
    # Same for elixir — the bundle runs under the target's per-major
    # Elixir, but the host orchestrator is Elixir 1.19.x.
    # shellcheck disable=SC2030,SC2031
    export AWFY_TARGET_ELIXIR_VERSION="$elixir_ver"
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

  # Per-ref `|| true` keeps a single bad ref from killing the whole
  # sweep — 30+ refs * jit/emu = 60+ measurements; one Hex/OpenSSL/
  # libc landmine shouldn't waste the rest. Failures show up as the
  # absence of a result dir under results/2026*; the next pass will
  # re-attempt them after fixes land.
  if [ "$major" -ge 24 ] || [ "$major" = "99" ]; then
    for flavor in $(echo "$FLAVORS" | tr ',' ' '); do
      run_modern "$ref" "$prefix" "$sha10" "$flavor" "$major" || \
        echo "  [warn] $ref [$flavor] failed — continuing"
    done
  else
    run_legacy "$ref" "$prefix" "$sha10" "$major" || \
      echo "  [warn] $ref legacy failed — continuing"
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
