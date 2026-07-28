#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
# Attach heap_probe to the live awfy-mongooseim-1 node and run a send + gc
# census while the Amoc scenario drives real online c2s sessions. Corruption-
# free: heap_probe.beam is compiled in a throwaway erlang:27.3 container
# (OTP-matched to the broker) and loaded via code:load_binary.
set -uo pipefail
C=awfy-mongooseim-1
HPDIR=priv/heap_probe

echo "[attach] compile heap_probe.beam with OTP 27.3 (matches the broker)"
docker run --rm -v "$PWD/$HPDIR:/w" -w /w erlang:27.3 erlc heap_probe.erl \
  || { echo "[attach] erlc failed"; exit 1; }

echo "[attach] discover node / cookie / escript inside $C"
NODE=$(docker exec "$C" mongooseimctl status 2>/dev/null | grep -oE 'mongooseim@[a-zA-Z0-9_.-]+' | head -1)
COOKIE=$(docker exec "$C" sh -c 'cat "$HOME/.erlang.cookie" 2>/dev/null || cat /var/lib/mongooseim/.erlang.cookie 2>/dev/null')
if [ -z "${COOKIE:-}" ]; then
  COOKIE=$(docker exec "$C" sh -c 'for f in $(find / -name vm.args 2>/dev/null); do grep -hoE "setcookie[[:space:]]+[A-Za-z0-9_]+" "$f"; done | head -1 | awk "{print \$2}"')
fi
ESCRIPT=$(docker exec "$C" sh -c 'command -v escript 2>/dev/null || find / -type f -name escript -path "*erts*bin*" 2>/dev/null | head -1')
echo "[attach] NODE=$NODE  COOKIE_set=${COOKIE:+yes}  ESCRIPT=$ESCRIPT"
[ -n "$NODE" ] && [ -n "${COOKIE:-}" ] && [ -n "$ESCRIPT" ] || { echo "[attach] discovery incomplete"; exit 1; }

docker cp "$HPDIR/heap_probe.beam" "$C:/tmp/heap_probe.beam"
docker cp "$HPDIR/census_xmpp.escript" "$C:/tmp/census_xmpp.escript"

echo "[attach] online sessions (sanity):"
docker exec "$C" mongooseimctl session countOnlineSessions 2>/dev/null \
  || docker exec "$C" mongooseimctl metrics getMetrics 2>/dev/null | grep -i session | head -3 \
  || true

echo "===== SEND census (20s, real online-session load) ====="
docker exec "$C" "$ESCRIPT" /tmp/census_xmpp.escript "$NODE" "$COOKIE" send 20000 /tmp/heap_probe.beam /tmp/hp_send.txt 2>&1 | tail -60
docker cp "$C:/tmp/hp_send.txt" /tmp/hp_send.txt 2>/dev/null || true

echo "===== GC census (8s) ====="
docker exec "$C" "$ESCRIPT" /tmp/census_xmpp.escript "$NODE" "$COOKIE" gc 8000 /tmp/heap_probe.beam /tmp/hp_gc.txt 2>&1 | tail -30
docker cp "$C:/tmp/hp_gc.txt" /tmp/hp_gc.txt 2>/dev/null || true
echo "[attach] done"
