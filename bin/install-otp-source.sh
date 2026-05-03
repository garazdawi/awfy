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

# Resolve to a SHA up front so the install path is content-addressed.
# Pre-resolved 40-hex SHAs are passed through as-is (ls-remote can't
# look up commit SHAs, only refs); anything else is resolved via the
# remote (tag, branch, etc.).
if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    SHA="$REF"
else
    SHA="$(git ls-remote https://github.com/erlang/otp.git "$REF" \
           | head -1 | cut -f1)"
fi

if [ -z "$SHA" ]; then
    echo "could not resolve $REF on erlang/otp"
    exit 1
fi

PREFIX="$PREFIX_BASE/$SHA"

if [ -x "$PREFIX/bin/erl" ] && "$PREFIX/bin/erl" -noshell -eval 'halt()' >/dev/null 2>&1; then
    echo "OTP $SHA already installed at $PREFIX"
    echo "$PREFIX"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching erlang/otp@$SHA …"
curl -fL "https://github.com/erlang/otp/archive/$SHA.tar.gz" \
    | tar xz -C "$WORK"
SRC="$WORK/otp-$SHA"

cd "$SRC"
export ERL_TOP="$SRC"

# Match the Linux Docker image's configure flags so cross-platform
# numbers compare apples-to-apples.
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
    --without-jinterface

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

echo "$PREFIX"
