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

if [ -x "$PREFIX/bin/erl" ] && "$PREFIX/bin/erl" -noshell -eval 'halt()' >/dev/null 2>&1; then
    echo "OTP $SHA already installed at $PREFIX" >&2
    echo "$PREFIX"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

{
    # Prefer the release `otp_src_<version>.tar.gz` when the ref is a
    # tagged OTP release: it ships prebuilt .beam files (saves the
    # erlc compilation pass — minutes of CPU on the GHA runner) and
    # has `configure` already generated (saves the autoconf step).
    # `/archive/<sha>.tar.gz` is the catch-all fallback (untagged
    # refs, very old releases without an asset).
    case "$REF" in
        OTP-*)
            VERSION="${REF#OTP-}"
            # Probe order:
            #   1. github.com/erlang/otp/releases — covers OTP 21+
            #      tagged releases.
            #   2. erlang.org/download — covers older majors (OTP 20.3
            #      etc.) and the major.minor "main" releases that
            #      predate github releases.
            for url in \
                "https://github.com/erlang/otp/releases/download/$REF/otp_src_$VERSION.tar.gz" \
                "https://erlang.org/download/otp_src_$VERSION.tar.gz"
            do
                if curl -fsLI -o /dev/null "$url"; then
                    echo "Fetching $url (prebuilt beams) …"
                    curl -fL "$url" | tar xz -C "$WORK"
                    SRC="$WORK/otp_src_$VERSION"
                    break
                fi
            done
            ;;
    esac
    if [ -z "${SRC:-}" ]; then
        echo "Fetching erlang/otp@$SHA via /archive (raw source) …"
        curl -fL "https://github.com/erlang/otp/archive/$SHA.tar.gz" \
            | tar xz -C "$WORK"
        SRC="$WORK/otp-$SHA"
    fi

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

    # OTP source tarballs from /archive/<sha>.tar.gz only ship
    # `configure.in` for pre-OTP 25 releases — autoconf is required
    # to generate `configure` itself. OTP's own `./otp_build autoconf`
    # wrapper does the right thing across versions (it knows where
    # nested configure.in files live).
    if [ ! -x ./configure ]; then
        echo "configure not present, running ./otp_build autoconf …"
        ./otp_build autoconf
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

    make -j"$JOBS"
    make install

    # Build and install the non-JIT (interpreter) emulator alongside the
    # default JIT one. After this, both `-emu_flavor jit` and
    # `-emu_flavor emu` resolve under the same prefix.
    make -j"$JOBS" FLAVOR=emu
    make FLAVOR=emu install

    # Verify the install runs at all. We don't try `-emu_flavor jit/emu`
    # here — the available flavor names changed across OTP versions
    # (OTP 26/27: `-emu_flavor smp`; OTP 28+: `jit`/`emu`). The fill
    # task's flavor argument is mapped per-version when we set ERL_FLAGS.
    "$PREFIX/bin/erl" -noshell -eval 'io:format("erl ok ~s~n",[erlang:system_info(otp_release)]),halt()'

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
