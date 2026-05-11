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
#     lib/otp_benchmarks/ebin/               # OtpBenchmarks suite,
#                                            # compiled under the target
#                                            # Elixir+OTP so phash2 /
#                                            # ETS / etc. families load
#                                            # on legacy targets.
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

# OtpBenchmarks suite — compile separately under the target Elixir
# so the .beam files are loadable on the target VM, then copy the
# resulting OTP-app directory into the bundle. We keep this as a
# distinct mix invocation rather than a path-dep of the harness
# sub-app: the harness ships its own pinned vendored deps and we
# don't want apps/otp_benchmarks/'s evolution to drag those.
#
# The target Elixir's `~> 1.9` floor (apps/otp_benchmarks/mix.exs)
# is what makes this compile work for OTP 20 / 21 / 22 / 23 —
# bumping it would silently drop OtpBenchmarks data on those legs.
echo "[build-target-bundle] compiling apps/otp_benchmarks under target Elixir" >&2
OTP_BENCH_APP="$AWFY_ROOT/apps/otp_benchmarks"
(
  cd "$OTP_BENCH_APP"
  mix compile >&2
)
OTP_BENCH_BUILD="$OTP_BENCH_APP/_build/prod/lib/otp_benchmarks"
[ -d "$OTP_BENCH_BUILD" ] || {
  echo "[build-target-bundle] expected $OTP_BENCH_BUILD after mix compile" >&2
  exit 1
}
cp -R "$OTP_BENCH_BUILD" "$BUNDLE/lib/"

# Sanity-check: the phash2 family beam landed in the bundle. If a
# new family is added without the build picking it up (e.g. a
# typo'd module name), this catches it before the bundle ships.
PHASH2_BEAM="$BUNDLE/lib/otp_benchmarks/ebin/Elixir.OtpBenchmarks.Benchmarks.Phash2.beam"
[ -f "$PHASH2_BEAM" ] || {
  echo "[build-target-bundle] phash2 family beam missing: $PHASH2_BEAM" >&2
  exit 1
}

# AWFY suite (Elixir + Erlang) — compile under the target Elixir so
# `Elixir.Awfy.Benchmarks.*` beams load on the target VM. Without
# this step the legacy bundle path silently drops every Elixir
# benchmark with `undef inner_benchmark_loop/1` — the Erlang side
# kept working because install-otp-source-mac.sh erlc's apps/awfy/src/
# into $PREFIX/awfy_target/awfy-0.1.0/ebin/, but the Elixir side has
# no equivalent (Elixir wasn't always available pre-OTP-23). Now
# that bin/install-elixir-source.sh is unconditional, mix compile
# here covers both languages from one source tree.
#
# `~> 1.9` floor in apps/awfy/mix.exs mirrors apps/otp_benchmarks/.
echo "[build-target-bundle] compiling apps/awfy under target Elixir" >&2
AWFY_APP="$AWFY_ROOT/apps/awfy"
(
  cd "$AWFY_APP"
  mix compile >&2
)
AWFY_BUILD="$AWFY_APP/_build/prod/lib/awfy"
[ -d "$AWFY_BUILD" ] || {
  echo "[build-target-bundle] expected $AWFY_BUILD after mix compile" >&2
  exit 1
}
# `-L` dereferences mix's `priv -> ../../../../priv` symlink so the
# fixture files end up as real files in the tarball — relative-path
# symlinks don't resolve inside the extracted bundle.
cp -RL "$AWFY_BUILD" "$BUNDLE/lib/"

# Sanity-check: a representative Elixir AWFY benchmark beam
# landed in the bundle. Bounce is the smallest one with no
# external deps, so it's the canonical "did the suite compile"
# witness.
BOUNCE_BEAM="$BUNDLE/lib/awfy/ebin/Elixir.Awfy.Benchmarks.Bounce.beam"
[ -f "$BOUNCE_BEAM" ] || {
  echo "[build-target-bundle] Elixir Bounce benchmark beam missing: $BOUNCE_BEAM" >&2
  exit 1
}

# Belt-and-braces: the canonical priv fixture is a real file, not
# the symlink mix leaves behind. Catches a future cp dropping `-L`.
RAP_JSON="$BUNDLE/lib/awfy/priv/rap_benchmark.json"
[ -f "$RAP_JSON" ] || {
  echo "[build-target-bundle] priv fixture missing: $RAP_JSON" >&2
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
