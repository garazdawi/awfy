#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# bin/measure-xmpp.sh — convenience wrapper around
# `mix awfy.measure_xmpp` that ensures Docker is callable before
# invocation. On macOS this auto-starts Colima (and stops it on exit
# iff we were the ones that started it — see bin/ensure-docker.sh).
# On Linux it's a thin pass-through.
#
# Usage — same flags as the mix task:
#
#     bin/measure-xmpp.sh
#     bin/measure-xmpp.sh --scenario dynamic_domains_pm --topology local
#     bin/measure-xmpp.sh --label before-mongoose-uplift
#
# Runs `mix awfy.measure_xmpp` with the supplied arguments and
# inherits its exit code. See `PLAN/MONGOOSEIM_BENCH_PLAN.md` for
# the broader design.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# Source the docker-ensure helper so its EXIT trap fires in *this*
# shell on script exit (otherwise Colima stays up after we're done).
# shellcheck source=bin/ensure-docker.sh disable=SC1091
. "$script_dir/ensure-docker.sh"

cd "$repo_root"
exec mix awfy.measure_xmpp "$@"
