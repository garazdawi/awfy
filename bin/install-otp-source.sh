#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Build OTP from source at a given git ref/SHA and install into a
# prefix. Used by the macOS self-hosted runner (and locally for
# manual measurement runs); the Linux GHA path uses the Dockerfile.
#
# Usage:
#   bin/install-otp-source.sh <git-ref> [<install-prefix>]
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
# capture stdout via `$(./install-otp-source.sh ...)` to get the prefix
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

    # Apply patches from $AWFY_ROOT/patches/OTP-<major>/*.patch — see
    # patches/README.md for the convention. Patches are sorted by
    # filename so prefixed numbers (01-foo.patch, 02-bar.patch) control
    # apply order when fixes depend on each other. (AWFY_ROOT was
    # resolved at the top of this script — see comment there.)
    case "$REF" in
        OTP-*) MAJOR="$(echo "$REF" | sed 's|^OTP-||' | cut -d. -f1)" ;;
        master|main) MAJOR="master" ;;
        maint-*) MAJOR="$(echo "$REF" | sed 's|^maint-||')" ;;
        *)
            # Resolve major from the source's OTP_VERSION file.
            if [ -f "$SRC/OTP_VERSION" ]; then
                MAJOR="$(head -1 "$SRC/OTP_VERSION" | cut -d. -f1)"
            else
                MAJOR=""
            fi
            ;;
    esac

    PATCH_DIR="$AWFY_ROOT/patches/OTP-$MAJOR"
    if [ -n "$MAJOR" ] && [ -d "$PATCH_DIR" ]; then
        for p in "$PATCH_DIR"/*.patch; do
            [ -f "$p" ] || continue
            echo "Applying $p"
            patch -p1 < "$p"
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
    ./configure \
        --prefix="$PREFIX" \
        --disable-debug \
        --without-javac \
        --without-wx \
        --without-odbc \
        --without-observer \
        --without-debugger \
        --without-megaco \
        --without-et \
        --without-jinterface \
        ${AWFY_OTP_EXTRA_CONFIGURE:-}

    # macOS reports CPU count via sysctl; Linux via nproc.
    if command -v nproc >/dev/null 2>&1; then
        JOBS="$(nproc)"
    else
        JOBS="$(sysctl -n hw.ncpu)"
    fi

    # Pre-OTP-26 trees race recursive subdir configure invocations
    # against compile in `make -j` — depending on scheduler timing you
    # see "config.h: No such file or directory" in erts/lib_src
    # (ethr_aux.c) or erts/emulator/hipe/hipe_mkliterals.c, even though
    # configure for that subdir succeeded. The bug is fixed in OTP 26
    # (build dep ordering cleanup); for older trees we cap to -j2 so
    # configure has time to finish before the racy compiles fire.
    if [ -n "${MAJOR:-}" ] && [ "$MAJOR" != "master" ] && [ "$MAJOR" -lt 26 ] 2>/dev/null; then
        JOBS=2
    fi

    make -j"$JOBS"
    make install

    # Build and install the non-JIT (interpreter) emulator alongside the
    # default JIT one. After this, both `-emu_flavor jit` and
    # `-emu_flavor emu` resolve under the same prefix.
    make -j"$JOBS" FLAVOR=emu
    make FLAVOR=emu install

    # `make FLAVOR=emu install` doesn't always copy beam.emu into
    # $PREFIX/lib/erlang/erts-VSN/bin/ — on some OTP versions the
    # binary lands in the source tree's bin/<TARGET>/ but the install
    # phase leaves the prefix with only beam.smp. erlexec then
    # answers `-emu_flavor emu` with "Invalid flavor". Do the copy
    # ourselves so the flag resolves on every Unix target. (Windows
    # uses install-otp-windows.ps1, not this script.)
    if [ -d "$ERL_TOP/bin" ]; then
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
        "$AWFY_ROOT"/apps/awfy/src/*.erl \
        "$AWFY_ROOT"/apps/awfy/src_target/*.erl
    cp -R "$AWFY_ROOT"/apps/awfy/priv/. "$TARGET_LIB/priv/" 2>/dev/null || true
} >&2

echo "$PREFIX"
