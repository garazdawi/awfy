#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Fetch OTP source for a given ref+SHA into $WORK_DIR/otp.
#
# Usage: bin/fetch-otp-source.sh <ref> <sha> <work-dir>
#
# Probe order (each prints to stderr; falls through on miss):
#   1. github.com/erlang/otp/releases/<ref>/otp_src_<version>.tar.gz
#      — covers OTP 21+ tagged releases (REF=OTP-*).
#   2. erlang.org/download/otp_src_<version>.tar.gz
#      — covers older majors (OTP 20.3 etc.) and major.minor "main"
#      releases that predate github releases.
#   3. erlang/otp's `otp_prebuilt` CI artifact via GitHub API
#      — covers branch / SHA refs (master, maint-*). Same content
#      as the release tarball (otp_src.tar.gz with prebuilt beams +
#      pre-run configure) uploaded by `Build and check Erlang/OTP`
#      for every commit. Requires GH_TOKEN (a personal token or
#      GITHUB_TOKEN both work; the artifact is public-readable).
#   4. github's auto-generated SHA/tag archive at
#      `github.com/erlang/otp/archive/<sha>.tar.gz`
#      — last-resort fallback for modern OTP (>= 24) when (3)
#      hasn't published yet for a fresh-pushed branch HEAD or
#      fresh-tagged release. Modern erlang/otp commits `configure`
#      under git, so the archive is buildable as-is; bootstrap
#      beams are recreated by `make`. **Not used for OTP < 24** —
#      those branches don't commit `configure` and we refuse to
#      run autoconf at fetch time (no guarantee the runner has the
#      right autoconf version, and regenerated configure breaks
#      the line-numbered `patches/OTP-X.Y/*.patch` series).
#
# (1)–(3) leave $WORK_DIR/otp/ as the canonical source dir with a
# pre-generated `configure` script and a pre-built bootstrap. (4)
# uses the in-tree `configure`; bootstrap beams are not needed
# because the downstream step builds from source anyway. If all
# applicable paths miss, the script exits non-zero rather than
# silently producing a degraded build.

set -euo pipefail

REF="${1:?ref required}"
SHA="${2:?sha required}"
WORK="${3:?work dir required}"

mkdir -p "$WORK"
cd "$WORK"

SRC=""

case "$REF" in
    OTP-*)
        VERSION="${REF#OTP-}"

        # Strategy 1: github.com release mirror over HTTPS curl.
        # Reliable for modern OTPs (post-OTP-21). --connect-timeout
        # 30 / --max-time 1800 / --speed-limit+--speed-time bound
        # the transfer so a stalled HTTPS pull falls through
        # quickly instead of wedging the build.
        github_url="https://github.com/erlang/otp/releases/download/$REF/otp_src_$VERSION.tar.gz"
        if curl -fsLI --connect-timeout 30 --max-time 60 -o /dev/null "$github_url"; then
            echo "fetch-otp-source: fetching $github_url (release tarball, github)" >&2
            curl -fL --connect-timeout 30 --max-time 1800 \
                --speed-limit 10240 --speed-time 60 \
                "$github_url" | tar xz
            SRC="otp_src_$VERSION"
        fi

        # Strategy 2: erlang.org mirror over rsync. github.com
        # doesn't have an `otp_src_X.Y.tar.gz` asset for older OTPs
        # (pre-21) — those are erlang.org-only. erlang.org's HTTPS
        # serves old tarballs at ~20 KB/s during US peak (88 MB
        # OTP-20.3 ran into our 30-min cap with curl on run
        # 25740656636); rsync over its native protocol is markedly
        # more reliable for those bulk downloads. The rsync host
        # and module name are documented at erlang.org/downloads
        # ("reachable through rsync rsync.erlang.org::erlang-
        # download").
        #
        # rsync requires `rsync` in the image — added to
        # Dockerfile.linux's otp-build apt list. Falls through to
        # the github archive fallback (strategy 4 below) if rsync
        # isn't installed or the daemon is unreachable.
        if [ -z "$SRC" ] && command -v rsync >/dev/null 2>&1; then
            rsync_url="rsync://rsync.erlang.org/erlang-download/otp_src_$VERSION.tar.gz"
            echo "fetch-otp-source: fetching $rsync_url (release tarball, erlang.org rsync)" >&2
            if rsync --contimeout=30 --timeout=60 \
                    "$rsync_url" "$WORK/otp_src.tar.gz" 2>&1 \
                && tar xzf "$WORK/otp_src.tar.gz"; then
                rm -f "$WORK/otp_src.tar.gz"
                SRC="otp_src_$VERSION"
            else
                echo "fetch-otp-source: rsync from erlang.org failed (no such ref or daemon unreachable)" >&2
                rm -f "$WORK/otp_src.tar.gz"
            fi
        fi
        ;;
esac

# Each curl|jq pipeline is wrapped with `|| var=""` because we're under
# `set -euo pipefail`: a 4xx response causes curl to exit non-zero and
# pipefail propagates it, aborting the script instead of cleanly falling
# through to the /archive fallback. We log each fall-through reason to
# stderr so a later "why didn't this use the prebuilt?" investigation
# has something to grep for.
#
# Query against the workflow file (.github/workflows/main.yaml in
# erlang/otp) rather than the global /actions/runs endpoint — the
# global one orders by created_at across every workflow, and on a busy
# repo the "Build and check Erlang/OTP" run gets pushed past per_page
# by Scorecard / Update PR details / Sync runs that fire on the same
# SHA. The workflow-scoped endpoint returns only that workflow's runs.
if [ -z "$SRC" ] && [ -n "${GH_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")
    base="https://api.github.com/repos/erlang/otp/actions/workflows/main.yaml/runs"
    # Walk up to 20 recent completed runs per query so a single
    # expired-artifact / artifact-less run (test-only failures still
    # publish, but artifact retention is ~90 days; an old still-on-
    # the-page run loses the artifact mid-life) doesn't force the
    # script back to the github-archive fallback. No
    # `conclusion == "success"` filter — the build job that uploads
    # otp_prebuilt succeeds even when downstream doc-check / test
    # legs fail the overall workflow.
    for q in "head_sha=$SHA" "branch=$REF"; do
        run_json="$(curl -fsSL --connect-timeout 30 --max-time 60 "${auth[@]}" "$base?$q&per_page=20" 2>/dev/null)" \
            || { echo "fetch-otp-source: $q query failed (curl)" >&2; continue; }
        run_ids="$(echo "$run_json" \
            | jq -r '.workflow_runs[] | select(.status == "completed") | .id' \
            2>/dev/null)" || run_ids=""
        if [ -z "$run_ids" ]; then
            echo "fetch-otp-source: $q matched no completed Build and check run" >&2
            continue
        fi
        for run_id in $run_ids; do
            # per_page=100 — main.yaml's run uploads 50+ artifacts
            # (per-suite test results, doc tarballs, scan results, …)
            # so the default page size of 30 can hide `otp_prebuilt`
            # past the first page. Bumping to the API max guarantees
            # we see it in one request.
            artifact_id="$(curl -fsSL --connect-timeout 30 --max-time 60 "${auth[@]}" \
                "https://api.github.com/repos/erlang/otp/actions/runs/$run_id/artifacts?per_page=100" 2>/dev/null \
                | jq -r '[.artifacts[] | select(.name == "otp_prebuilt" and .expired == false)][0].id // empty' \
                2>/dev/null)" || artifact_id=""
            if [ -z "$artifact_id" ]; then
                echo "fetch-otp-source: run $run_id has no unexpired otp_prebuilt artifact" >&2
                continue
            fi
            echo "fetch-otp-source: fetching otp_prebuilt artifact $artifact_id (run $run_id)" >&2
            # The zip is ~150 MB. Default curl has no timeout, which
            # wedged a build-linux master leg for 15+ min on run
            # 25738975590. --connect-timeout 30 fails fast on DNS /
            # TCP handshake stalls. --speed-limit / --speed-time
            # aborts on stalled transfers (under 10 KB/s for 60s)
            # while letting slow-but-progressing downloads finish.
            # --max-time 1800 is a 30-min hard cap. Falling through
            # to the next strategy is strictly better than burning
            # runner minutes on a stuck curl.
            if ! curl -fsSL -L "${auth[@]}" \
                --connect-timeout 30 \
                --max-time 1800 \
                --speed-limit 10240 --speed-time 60 \
                "https://api.github.com/repos/erlang/otp/actions/artifacts/$artifact_id/zip" \
                -o "$WORK/prebuilt.zip" 2>/dev/null; then
                echo "fetch-otp-source: artifact $artifact_id download failed (timeout or curl error)" >&2
                rm -f "$WORK/prebuilt.zip"
                continue
            fi
            if ! unzip -q "$WORK/prebuilt.zip" -d "$WORK/prebuilt"; then
                echo "fetch-otp-source: artifact $artifact_id unzip failed" >&2
                continue
            fi
            if ! tar xzf "$WORK/prebuilt/otp_src.tar.gz"; then
                echo "fetch-otp-source: artifact $artifact_id tarball extract failed" >&2
                continue
            fi
            # The artifact's tarball extracts to "otp/" already.
            SRC="otp"
            break
        done
        [ -n "$SRC" ] && break
    done
fi

# Last-resort fallback: github's auto-generated tag/SHA archive. The
# bootstrap beams aren't there but `make` rebuilds them; what matters
# is that `configure` is present so we don't have to invoke autoconf
# at fetch time (we can't trust that the runner has the exact
# autoconf version erlang/otp's tree was generated with, and a
# regenerated configure has different line numbers from the canonical
# one — patches in `patches/OTP-X.Y/*.patch` would silently fail to
# apply). This works because modern erlang/otp commits `configure`
# under git; older versions don't.
#
# **Modern OTP only (>= 24).** For OTP < 24 the archive lacks
# `configure` entirely (it was .gitignored in those branches) and
# even if it weren't, the patches in `patches/OTP-X.Y/*.patch` are
# line-numbered against the canonical release tarball's `configure`,
# which can drift from the in-tree version. Old OTPs must come from
# the canonical release tarball; better to fail loudly than mis-build.
# master/maint always count as modern; numeric majors must be >= 24.
modern_otp=0
case "$REF" in
    master|maint) modern_otp=1 ;;
    maint-*)
        v="${REF#maint-}"
        if [ "$v" -ge 24 ] 2>/dev/null; then modern_otp=1; fi
        ;;
    OTP-*)
        v="${REF#OTP-}"
        v="${v%%.*}"
        if [ "$v" -ge 24 ] 2>/dev/null; then modern_otp=1; fi
        ;;
esac

if [ -z "$SRC" ] && [ "$modern_otp" = "1" ]; then
    archive_url="https://github.com/erlang/otp/archive/$SHA.tar.gz"
    if curl -fsLI --connect-timeout 30 --max-time 60 -o /dev/null "$archive_url"; then
        echo "fetch-otp-source: falling back to $archive_url" >&2
        if curl -fL --connect-timeout 30 --max-time 1800 \
                --speed-limit 10240 --speed-time 60 \
                "$archive_url" | tar xz; then
            # SC2012: github's archive extracts to otp-<SHA>, no
            # spaces or special chars in the dirname. Glob is fine.
            # shellcheck disable=SC2012
            extracted="$(ls -d otp-* 2>/dev/null | head -1)"
            if [ -n "$extracted" ] && [ -f "$extracted/configure" ]; then
                SRC="$extracted"
            elif [ -n "$extracted" ]; then
                echo "fetch-otp-source: archive at $SHA has no committed configure script; refusing to autoconf at fetch time" >&2
                rm -rf "$extracted"
            else
                echo "fetch-otp-source: archive extract produced no tree" >&2
            fi
        fi
    fi
fi

if [ -z "$SRC" ]; then
    echo "fetch-otp-source: no buildable source found for ref=$REF sha=$SHA" >&2
    if [ "$modern_otp" = "1" ]; then
        echo "  paths tried: release tarball (github), erlang.org tarball, otp_prebuilt artifact, github archive fallback" >&2
        echo "  archive fallback requires a committed configure script (modern erlang/otp commits it; if missing, the SHA is too old)." >&2
    else
        echo "  paths tried: release tarball (github), erlang.org tarball, otp_prebuilt artifact" >&2
        echo "  archive fallback intentionally disabled for OTP < 24 — those branches don't commit configure" >&2
        echo "  and patches/OTP-X.Y/*.patch are line-numbered against the canonical release tarball." >&2
        echo "  Wait for the upstream release tarball, or use a newer ref." >&2
    fi
    exit 1
fi

# Canonicalise to $WORK/otp regardless of which path produced the source.
if [ "$SRC" != "otp" ]; then
    rm -rf "$WORK/otp"
    mv "$WORK/$SRC" "$WORK/otp"
fi

# Tidy up artefact-fetch leftovers so a downstream tarball of $WORK
# doesn't ship them.
rm -rf "$WORK/prebuilt" "$WORK/prebuilt.zip"
