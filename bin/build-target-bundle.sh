#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Build the AWFY target-Elixir bundle: a self-contained tarball
# containing Elixir, the vendored Benchee/deep_merge/statistex deps,
# and the pre-compiled `Awfy.TargetRunner` script. The bundle is
# extracted on the target host and invoked via `erl -s` per
# benchmark — see PLAN/TARGET_ELIXIR_RUNNER_PLAN.md § Architecture.
#
# Usage:
#   bin/build-target-bundle.sh <otp_install_dir> <elixir_version> [<output_path>]
#
# Defaults:
#   output_path = ./target_bundle_<elixir_version>.tar.gz
#
# The script does NOT source-build OTP. The caller supplies a pre-
# built install directory:
#   * In CI, prep-target-bundle (Phase 2) extracts /opt/otp from
#     the per-OTP-SHA Docker image produced by build-linux via
#     bin/extract-otp-from-image.sh and passes the path here. OTP
#     is built once per SHA across the whole workflow.
#   * Locally, run bin/install-otp-source-mac.sh first and pass the
#     prefix it prints.
#
# Bundle layout (matches PLAN/TARGET_ELIXIR_RUNNER_PLAN.md
# § Architecture):
#
#   bundle/
#     bin/                                   # Elixir wrapper scripts
#     lib/elixir/ebin/                       # Elixir core
#     lib/{eex,ex_unit,iex,logger,mix}/ebin/ # Elixir sub-apps
#     lib/awfy_target_runner/{ebin,priv}/    # this sub-app
#     lib/{benchee,deep_merge,statistex}/ebin/  # vendored deps
#
# All file paths inside the bundle are relative; extract anywhere
# and invoke `bundle/bin/elixir` (target erl must be on PATH or
# pointed to via $ERTS_BIN).

set -euo pipefail

usage() {
  echo "usage: $0 <otp_install_dir> <elixir_version> [<output_path>]" >&2
  echo "  e.g. $0 ~/.local/otp/<sha> 1.9.4 ./target_bundle_1.9.4.tar.gz" >&2
  exit 2
}

OTP_PREFIX="${1:-}"
ELIXIR_VERSION="${2:-}"
[ -n "$OTP_PREFIX" ] || usage
[ -n "$ELIXIR_VERSION" ] || usage

OUTPUT="${3:-target_bundle_${ELIXIR_VERSION}.tar.gz}"

# Resolve repo root up front; we cd into the sub-app to mix-compile.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWFY_ROOT="${AWFY_ROOT:-$(dirname "$SCRIPT_DIR")}"
SUBAPP="$AWFY_ROOT/apps/awfy_target_runner"

[ -x "$OTP_PREFIX/bin/erl" ] || {
  echo "[build-target-bundle] $OTP_PREFIX is not an OTP install (no bin/erl)" >&2
  exit 1
}
[ -d "$SUBAPP" ] || {
  echo "[build-target-bundle] expected sub-app at $SUBAPP" >&2
  exit 1
}

# Build Elixir against the supplied OTP. Idempotent — caches at
# ~/.local/elixir-src/<version>/.
echo "[build-target-bundle] resolving Elixir $ELIXIR_VERSION" >&2
ELIXIR_DIR="$("$SCRIPT_DIR/install-elixir-source.sh" "$ELIXIR_VERSION" "$OTP_PREFIX")"
[ -x "$ELIXIR_DIR/bin/elixir" ] || {
  echo "[build-target-bundle] install-elixir-source.sh did not produce $ELIXIR_DIR/bin/elixir" >&2
  exit 1
}

# Stage area we'll tar at the end. Don't pollute /tmp with
# left-overs on success.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Always run mix invocations under an isolated MIX_HOME. Appendix C:
# if a stale ~/.mix/archives/hex-*.archive (compiled for a newer OTP)
# is on the path, OTP 20's emulator refuses to load it with "Use of
# opcode 177; this emulator supports only up to 159". The bundle
# pipeline never needs Hex, but mix tries to load installed archives
# unconditionally on startup. Hard-isolate.
export MIX_HOME="$STAGE/mix_home"
export MIX_ENV=prod
export PATH="$OTP_PREFIX/bin:$ELIXIR_DIR/bin:$PATH"

# `mix local.hex` would also need an isolated MIX_HOME; skip
# entirely — vendored deps don't need Hex.
echo "[build-target-bundle] compiling sub-app + vendored deps under MIX_ENV=prod" >&2
(
  cd "$SUBAPP"
  # `deps.get` is a no-op when every dep is path-based, but mix still
  # writes mix.lock entries; running it explicitly keeps the output
  # deterministic when refresh-target-deps re-applies versions.
  mix deps.get >&2
  mix deps.compile >&2
  mix compile >&2
)

# Layout: bundle/{bin,lib/elixir,lib/<app>/...}.
BUNDLE="$STAGE/bundle"
mkdir -p "$BUNDLE/bin" "$BUNDLE/lib"

# Copy Elixir runtime: bin/ scripts + every Elixir sub-app's ebin.
# Strip src/ and test/ from each sub-app — they're not needed at
# runtime and bloat the bundle by ~3-4× on disk. Don't try to
# enumerate sub-apps; just copy lib/, then prune.
cp -R "$ELIXIR_DIR/bin/." "$BUNDLE/bin/"
cp -R "$ELIXIR_DIR/lib/." "$BUNDLE/lib/"
# Per-sub-app prune. shopt is bash-specific; the script's shebang
# requires bash so this is safe.
shopt -s nullglob
for sub in "$BUNDLE/lib"/*/; do
  rm -rf "$sub/src" "$sub/test" "$sub/priv-tests"
done
shopt -u nullglob

# Sub-app + vendored deps: mix put them under
# apps/awfy_target_runner/_build/prod/lib/<app>/{ebin,priv}/. That's
# already the OTP-app shape we need (Appendix D — priv/ as peer of
# ebin/, not sibling). Copy the whole tree.
BUILD_LIB="$SUBAPP/_build/prod/lib"
[ -d "$BUILD_LIB" ] || {
  echo "[build-target-bundle] expected $BUILD_LIB after mix compile" >&2
  exit 1
}
cp -R "$BUILD_LIB/." "$BUNDLE/lib/"

# Sanity-check: the runner module beam landed where erl -s expects.
RUNNER_BEAM="$BUNDLE/lib/awfy_target_runner/ebin/Elixir.Awfy.TargetRunner.beam"
[ -f "$RUNNER_BEAM" ] || {
  echo "[build-target-bundle] runner beam missing: $RUNNER_BEAM" >&2
  exit 1
}

# Tar from $STAGE so the archive root is `bundle/`.
mkdir -p "$(dirname "$OUTPUT")"
tar czf "$OUTPUT" -C "$STAGE" bundle

# Belt-and-braces: make sure the tarball actually materialised. Local
# smoke-testing once hit a case where the script appeared to exit 0
# right after install-elixir-source.sh returned, with no tar output
# and no error — `set -e` should have caught it but didn't. Failing
# loudly here means a silent regression next time gets caught at
# the end of the build instead of in the smoke step that consumes
# this bundle.
[ -s "$OUTPUT" ] || {
  echo "[build-target-bundle] expected tarball at $OUTPUT but file is missing or empty" >&2
  exit 1
}

ABS_OUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
SIZE="$(du -h "$ABS_OUT" | awk '{print $1}')"
echo "[build-target-bundle] wrote $ABS_OUT ($SIZE)" >&2
echo "$ABS_OUT"
