# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Ensure Docker is callable on this host.
#
# Linux: assumed already provided by the host setup (GHA runners,
# AWS instances). This script is a no-op.
#
# macOS: auto-start Colima if not running, and install an EXIT trap
# in the *parent* shell that stops it again iff we were the ones that
# started it. Users who pre-`colima start` keep full lifecycle
# control (fast iterative dev); cold one-shot invocations clean up
# after themselves.
#
# Usage — SOURCE this file from a parent script. Do NOT invoke as a
# subshell; the EXIT trap must run in the parent's process so the
# stop-Colima step fires on script exit.
#
#     . "$(dirname "$0")/ensure-docker.sh"
#     # ... do work that needs Docker ...
#
# Generic, not benchmark-specific — used by both the MongooseIM /
# XMPP bench path and (when implemented) the network bench path.

if [ "$(uname -s)" != "Darwin" ]; then
    # Linux / other Unix — Docker is part of the host setup. Nothing
    # to do, including no trap (we don't manage a lifecycle we didn't
    # start).
    return 0 2>/dev/null || exit 0
fi

if ! command -v colima >/dev/null 2>&1; then
    echo "ensure-docker: macOS host without colima — install with:" >&2
    echo "  brew install colima docker docker-compose" >&2
    return 1 2>/dev/null || exit 1
fi

# `colima status` exits 0 only when the default profile is running.
# If it already is, the user (or a prior invocation) owns the lifecycle —
# we don't install a trap that would stop it from under them.
if colima status >/dev/null 2>&1; then
    return 0 2>/dev/null || exit 0
fi

echo "ensure-docker: starting Colima (cpu=4 memory=8 vm-type=vz mount-type=virtiofs)" >&2
colima start --cpu 4 --memory 8 --vm-type vz --mount-type virtiofs

# Marker file: presence means *we* started Colima this invocation
# and should stop it on exit. Per-PID so concurrent invocations don't
# step on each other's marker.
__awfy_colima_marker="${TMPDIR:-/tmp}/awfy-started-colima.$$"
touch "$__awfy_colima_marker"

__awfy_stop_colima_if_we_started() {
    if [ -f "$__awfy_colima_marker" ]; then
        rm -f "$__awfy_colima_marker"
        echo "ensure-docker: stopping Colima (we started it)" >&2
        colima stop >/dev/null 2>&1 || true
    fi
}

# Compose with any pre-existing EXIT trap rather than clobbering it.
__awfy_prev_exit_trap="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
if [ -n "$__awfy_prev_exit_trap" ]; then
    trap "__awfy_stop_colima_if_we_started; $__awfy_prev_exit_trap" EXIT
else
    trap __awfy_stop_colima_if_we_started EXIT
fi
