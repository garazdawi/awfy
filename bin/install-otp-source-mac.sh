#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Build OTP from source at a given git ref/SHA and install into a
# prefix.
#
# Used in two places:
#   * macOS measure-{macos,macos-target} jobs in bench.yml — there's
#     no Linux Docker for macOS, so source-build is the only option.
#   * Local target-bundle development — operator runs this once per
#     target OTP, then feeds the prefix to bin/build-target-bundle.sh.
#
# The Linux measure path goes through Dockerfile.linux for both
# modern (build-linux) and legacy (build-linux-target) — Phase 3 of
# PLAN/TARGET_ELIXIR_RUNNER_PLAN.md unified those. So this script
# is effectively macOS-only on CI; the `-mac` suffix in the
# filename makes that clear.
#
# Usage:
#   bin/install-otp-source-mac.sh <git-ref> [<install-prefix>]
#
# Defaults:
#   install-prefix = $HOME/.local/otp/<sha>
#
# Idempotent: if the prefix already exists with a working `erl`, the
# script exits 0 without rebuilding (lets the workflow short-circuit
# repeated runs of the same OTP SHA).

set -euo pipefail

REF="${1:?git ref required}"
PREFIX_BASE="${2:-$HOME/.local/otp}"

# Resolve the awfy repo root up front. We `cd "$SRC"` further down
# before invoking the target-beam compile, so $0-relative paths stop
# resolving correctly past that point — pin AWFY_ROOT here while CWD
# is still whatever the caller invoked us from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWFY_ROOT="${AWFY_ROOT:-$(dirname "$SCRIPT_DIR")}"

# Resolve to a *commit* SHA up front so the install path is
# content-addressed. Pre-resolved 40-hex SHAs are passed through.
# Annotated tags (which is how OTP releases tag) need `^{}` to
# dereference from the tag-object SHA to the commit SHA — without
# it, the install prefix would key on the tag object and never
# match the commit-SHA cache key the workflow uses. The fallback
# to plain `$REF` covers branches and lightweight tags, which
# return empty for `^{}`.
if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    SHA="$REF"
else
    SHA="$(git ls-remote https://github.com/erlang/otp.git "$REF^{}" \
           | head -1 | cut -f1)"
    if [ -z "$SHA" ]; then
        SHA="$(git ls-remote https://github.com/erlang/otp.git "$REF" \
               | head -1 | cut -f1)"
    fi
fi

if [ -z "$SHA" ]; then
    echo "could not resolve $REF on erlang/otp" >&2
    exit 1
fi

PREFIX="$PREFIX_BASE/$SHA"

# Everything except the final `echo "$PREFIX"` writes to stderr. Callers
# capture stdout via `$(./install-otp-source-mac.sh ...)` to get the prefix
# back, and a single `make install` run can produce megabytes of output
# (xmerl in OTP 26 has so many .beam files that one `/usr/bin/install`
# line exceeds MAXPATHLEN — leaking that into stdout corrupts GITHUB_PATH
# and triggers ENAMETOOLONG in the GHA runner).

# Skip the slow OTP build if the install prefix already has a working
# `erl`. We still re-do the target-beam compile below — the awfy
# sources can change without the OTP SHA changing, and the GHA cache
# keys only on the OTP SHA. Always rebuilding the target beams is
# cheap (<10s) compared to baking the source hash into the cache key.
OTP_INSTALLED=0
if [ -x "$PREFIX/bin/erl" ] && "$PREFIX/bin/erl" -noshell -eval 'halt()' >/dev/null 2>&1; then
    echo "OTP $SHA already installed at $PREFIX, recompiling target beams only" >&2
    OTP_INSTALLED=1
fi

# Coarse OTP-major derivation from $REF, used for the elixir-for-otp.sh
# lookup at the tail of the script. Done BEFORE the OTP_INSTALLED
# guard so re-running on a cached prefix still picks the right Elixir.
# `master`/`maint` pass through verbatim — elixir-for-otp.sh treats
# anything non-numeric as modern.
case "$REF" in
    OTP-*)         OTP_MAJOR="$(echo "${REF#OTP-}" | cut -d. -f1)" ;;
    maint-*)       OTP_MAJOR="${REF#maint-}" ;;
    master|maint)  OTP_MAJOR="$REF" ;;
    *)             OTP_MAJOR="$REF" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
    if [ "$OTP_INSTALLED" = "1" ]; then
        : "skipping fetch+build, jumping to target-beam compile"
    else
    # Source resolution (release tarball → otp_prebuilt artifact →
    # /archive fallback) is shared with Dockerfile.linux; see
    # bin/fetch-otp-source.sh for the probe order. Set GH_TOKEN
    # before invoking to enable the artifact path; the /archive
    # fallback covers the unauthenticated case.
    GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" \
        "$SCRIPT_DIR/fetch-otp-source.sh" "$REF" "$SHA" "$WORK"
    SRC="$WORK/otp"

    cd "$SRC"
    export ERL_TOP="$SRC"

    # Apply patches from $AWFY_ROOT/patches/OTP-<major>.<minor>/*.patch
    # — see patches/README.md for the convention. Patches are sorted
    # by filename so prefixed numbers (01-foo.patch, 02-bar.patch)
    # control apply order when fixes depend on each other. Each
    # function-release line (e.g. 23.0, 23.1, 23.2, 23.3) gets its
    # own directory, holding only the patches that are missing from
    # that line's source — patches already merged upstream into a
    # given function-release are simply not present in its directory,
    # so we can forward-apply unconditionally without dry-run /
    # reverse-apply heuristics. Shared patches across minor lines are
    # kept as symlinks into a sibling directory. (AWFY_ROOT was
    # resolved at the top of this script — see comment there.)
    case "$REF" in
        OTP-*)
            REF_VER="${REF#OTP-}"
            MAJOR_MINOR="$(echo "$REF_VER" | cut -d. -f1-2)"
            ;;
        master) MAJOR_MINOR="master" ;;
        maint-*)
            # `maint-23` tracks the highest minor in OTP-23; we don't
            # know which one without resolving, so look at the source.
            if [ -f "$SRC/OTP_VERSION" ]; then
                MAJOR_MINOR="$(head -1 "$SRC/OTP_VERSION" | cut -d. -f1-2)"
            else
                MAJOR_MINOR=""
            fi
            ;;
        *)
            # Resolve from the source's OTP_VERSION file.
            if [ -f "$SRC/OTP_VERSION" ]; then
                MAJOR_MINOR="$(head -1 "$SRC/OTP_VERSION" | cut -d. -f1-2)"
            else
                MAJOR_MINOR=""
            fi
            ;;
    esac

    PATCH_DIR="$AWFY_ROOT/patches/OTP-$MAJOR_MINOR"
    if [ -n "$MAJOR_MINOR" ] && [ -d "$PATCH_DIR" ]; then
        for p in "$PATCH_DIR"/*.patch; do
            [ -f "$p" ] || continue
            echo "Applying $p"
            patch -p1 -N < "$p"
        done
    fi

    # Match the Linux Docker image's configure flags so cross-platform
    # numbers compare apples-to-apples. AWFY_OTP_EXTRA_CONFIGURE lets
    # the caller bolt on additional flags — used by the target-runner
    # CI path to pass `--without-ssl` for OTP < 23 (whose crypto NIF
    # needs APIs OpenSSL 3 removed) without affecting newer OTPs that
    # build crypto fine against either OpenSSL version. Future
    # benchmarks that exercise crypto will run on those newer targets
    # unaffected.
    #
    # SC2086 is intentional on the trailing AWFY_OTP_EXTRA_CONFIGURE
    # expansion: callers may pass multiple flags as one env var
    # (e.g. "--without-ssl --without-ssh"), and we want bash word-
    # splitting to turn that into separate configure args. Quoting
    # would pass the whole string as a single argument.
    #
    # CFLAGS="-O2 -fcommon": same fix as the Linux Dockerfile —
    # `-fcommon` re-enables the pre-GCC-10/pre-Xcode-12 lenient
    # treatment of tentative definitions (OTP < 23 source has
    # several declared in headers without `extern`); `-O2` replaces
    # autoconf's default optimisation level since touching CFLAGS
    # at all suppresses its built-in `-g -O2` injection, and OTP's
    # configure tests depend on optimisation being on. No-op for
    # OTP ≥ 23 where the declarations are properly extern-qualified.
    # OpenSSL location: Homebrew installs to a non-default prefix
    # on Apple Silicon (/opt/homebrew/opt/openssl@3). Without
    # `--with-ssl=...`, configure default-skipped the crypto NIF on
    # legacy OTPs (20-24), leaving the prefixes without a crypto
    # module — `crypto:hash/2` and friends became `undef`. Auto-
    # detect via `brew --prefix`; CI macos-latest does the same in
    # bench.yml.
    SSL_FLAG=""
    if command -v brew >/dev/null 2>&1; then
        SSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
        if [ -n "$SSL_PREFIX" ] && [ -d "$SSL_PREFIX" ]; then
            SSL_FLAG="--with-ssl=$SSL_PREFIX"
        fi
    fi

    # --disable-pgo: OTP's PGO trains on estone_SUITE, which is a mixed
    # workload. On macOS-arm64 (Apple Clang -fprofile-instr-*) the
    # resulting profile re-orders the beam_emu dispatch table in a way
    # that hurts tight hot loops — the exact shape most AWFY/microbench
    # scenarios are. Measured on OTP-23.1.5: PGO-on is 8–12% slower
    # than PGO-off on countdown + recursive-fib; flat on list/binary
    # workloads; no shape sped up. Active range is OTP-21.0–23.x: pre-
    # 21.0 has no PGO machinery; OTP-24.0 (BeamAsm JIT) hardcoded
    # USE_PGO=false in erts/configure, so the flag is a no-op on ≥24
    # and a benign warning on ≤20.
    #
    # shellcheck disable=SC2086
    CFLAGS="-O2 -fcommon ${CFLAGS:-}" \
    ./configure \
        --prefix="$PREFIX" \
        --disable-debug \
        --disable-pgo \
        --without-javac \
        --without-wx \
        --without-odbc \
        --without-observer \
        --without-debugger \
        --without-megaco \
        --without-et \
        --without-jinterface \
        ${SSL_FLAG} \
        ${AWFY_OTP_EXTRA_CONFIGURE:-}

    # macOS reports CPU count via sysctl; Linux via nproc.
    if command -v nproc >/dev/null 2>&1; then
        JOBS="$(nproc)"
    else
        JOBS="$(sysctl -n hw.ncpu)"
    fi

    # V=1 enables verbose recipe printing so failure logs show the
    # actual gcc command line, including the configure-substituted
    # absolute -I${ERL_TOP}/erts/<host> that locates config.h. The
    # default pretty-printer hides those.
    make V=1 -j"$JOBS"
    make V=1 install

    # Build and install the non-JIT (interpreter) emulator alongside the
    # default JIT one. After this, both `-emu_flavor jit` and
    # `-emu_flavor emu` resolve under the same prefix.
    make V=1 -j"$JOBS" FLAVOR=emu
    make V=1 FLAVOR=emu install

    # `make FLAVOR=emu install` doesn't always copy beam.emu into
    # $PREFIX/lib/erlang/erts-VSN/bin/ — on some OTP versions the
    # binary lands in the source tree's bin/<TARGET>/ but the install
    # phase leaves the prefix with only beam.smp. erlexec then
    # answers `-emu_flavor emu` with "Invalid flavor". Do the copy
    # ourselves so the flag resolves on every Unix target. (Windows
    # uses install-otp-windows.ps1, not this script.)
    if [ -d "$ERL_TOP/bin" ]; then
        # SC2012: glob-listing controlled paths is fine here — the
        # erts-VSN dirs are written by `make install` and never have
        # spaces or special chars.
        # shellcheck disable=SC2012
        erts_bin="$(ls -d "$PREFIX"/lib/erlang/erts-*/bin 2>/dev/null | head -1)"
        if [ -n "$erts_bin" ]; then
            for src in "$ERL_TOP"/bin/*/beam.emu; do
                [ -f "$src" ] || continue
                cp "$src" "$erts_bin/beam.emu"
                echo "Copied $(basename "$(dirname "$src")")/beam.emu → $erts_bin/" >&2
                break
            done
        fi
    fi

    # Record the perf-relevant build inputs for `mix awfy.measure` to
    # surface in meta.json (and the dashboard's machine-specs card).
    # Skip --without-* (just trimming the build), --disable-debug
    # (default anyway), and --prefix (boilerplate) — they're noise
    # for a performance comparison.
    {
        printf 'CFLAGS="-O2 -fcommon %s"\n' "${CFLAGS:-}"
        printf -- '--disable-pgo\n'
        [ -n "$SSL_FLAG" ] && printf '%s\n' "$SSL_FLAG"
        [ -n "${AWFY_OTP_EXTRA_CONFIGURE:-}" ] && printf '%s\n' "${AWFY_OTP_EXTRA_CONFIGURE}"
    } > "$PREFIX/awfy_build_config.txt"

    # Honest compiler identity: erlang:system_info(c_compiler_used) on
    # macOS reports {gnuc, {4,2,1}} because Apple's clang sets the
    # __GNUC__ macros for compat, and OTP's detection reads those.
    # Capture the actual `$CC --version` first line here so the
    # dashboard can show "Apple clang version 15.0.0" instead of a
    # 17-year-old GCC stub. awfy.measure prefers this file when set.
    "${CC:-cc}" --version 2>/dev/null | head -1 > "$PREFIX/awfy_compiler.txt" || true

    # Verify the install runs at all. We don't try `-emu_flavor jit/emu`
    # here — the available flavor names changed across OTP versions
    # (OTP 26/27: `-emu_flavor smp`; OTP 28+: `jit`/`emu`). The fill
    # task's flavor argument is mapped per-version when we set ERL_FLAGS.
    "$PREFIX/bin/erl" -noshell -eval 'io:format("erl ok ~s~n",[erlang:system_info(otp_release)]),halt()'
    fi  # OTP_INSTALLED guard

    # Compile the benchmark suite + target harness with the *target*
    # erlc, into an OTP-app-shaped layout under $PREFIX/lib/awfy-0.1.0/.
    # `code:priv_dir(awfy)` finds priv via the awfy-VSN convention, so
    # the Json benchmark's `priv/rap_benchmark.json` lookup keeps
    # working under the peer.
    #
    # We only compile Erlang sources here. Elixir benchmarks under
    # `apps/awfy/lib/awfy/benchmarks/` need the target's Elixir, which
    # isn't always installed (and doesn't exist for OTP < 23). The
    # workflow either installs target Elixir and adds a separate
    # `mix compile` step, or skips Elixir benchmarks for that target.
    # Target beams go under $PREFIX/awfy_target/awfy-0.1.0/ rather than
    # $PREFIX/lib/ so they don't show up to the host's `mix` as a
    # competing OTP-app named `awfy` when ERL_LIBS happens to include
    # the prefix. Caller sets:
    #   AWFY_TARGET_ERL=$PREFIX/bin/erl
    #   AWFY_TARGET_BEAMS=$PREFIX/awfy_target/awfy-0.1.0/ebin
    #
    # Compile awfy_benchmark first so the behaviour file is available
    # when the modules that `-behaviour(awfy_benchmark)` get compiled.
    TARGET_LIB="$PREFIX/awfy_target/awfy-0.1.0"
    mkdir -p "$TARGET_LIB/ebin" "$TARGET_LIB/priv"
    "$PREFIX/bin/erlc" -o "$TARGET_LIB/ebin" \
        "$AWFY_ROOT"/apps/awfy/src/awfy_benchmark.erl \
        "$AWFY_ROOT"/apps/awfy/src/awfy_random.erl \
        "$AWFY_ROOT"/apps/awfy/src/awfy_som_vector.erl
    # -pa $TARGET_LIB/ebin: makes the just-compiled awfy_benchmark.beam
    # visible to the second pass so behaviour-conformance checks on the
    # benchmark modules don't print "behaviour awfy_benchmark undefined".
    "$PREFIX/bin/erlc" -pa "$TARGET_LIB/ebin" -o "$TARGET_LIB/ebin" \
        "$AWFY_ROOT"/apps/awfy/src/*.erl
    cp -R "$AWFY_ROOT"/apps/awfy/priv/. "$TARGET_LIB/priv/" 2>/dev/null || true

    # Build/install Elixir alongside this OTP, version pinned by
    # bin/elixir-for-otp.sh — single source of truth shared with
    # bench.yml's "Pin Elixir version" steps. install-elixir-source
    # is idempotent and caches at $HOME/.local/elixir-src/<ver>, so
    # multiple modern OTPs share one Elixir build. $OTP_MAJOR was
    # derived earlier (before the OTP_INSTALLED guard) so this works
    # on both fresh-build and cache-hit paths.
    ELIXIR_VERSION="$("$SCRIPT_DIR/elixir-for-otp.sh" "$OTP_MAJOR")"
    "$SCRIPT_DIR/install-elixir-source.sh" "$ELIXIR_VERSION" "$PREFIX" >&2
} >&2

echo "$PREFIX"
