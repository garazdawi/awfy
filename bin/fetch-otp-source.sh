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
        for url in \
            "https://github.com/erlang/otp/releases/download/$REF/otp_src_$VERSION.tar.gz" \
            "https://erlang.org/download/otp_src_$VERSION.tar.gz"
        do
            if curl -fsLI -o /dev/null "$url"; then
                echo "fetch-otp-source: fetching $url (release tarball)" >&2
                curl -fL "$url" | tar xz
                SRC="otp_src_$VERSION"
                break
            fi
        done
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
    for q in "head_sha=$SHA" "branch=$REF"; do
        run_json="$(curl -fsSL "${auth[@]}" "$base?$q&per_page=5" 2>/dev/null)" \
            || { echo "fetch-otp-source: $q query failed (curl)" >&2; continue; }
        # No `conclusion == "success"` filter — the workflow uploads
        # `otp_prebuilt` from the build-side job, but a doc-check or
        # test-leg failure later in the same workflow run flips the
        # overall conclusion to "failure" even though the artifact is
        # perfectly usable. Filter on `status == "completed"` so we
        # don't grab an in-flight run whose artifact isn't uploaded
        # yet; the artifact-existence check below handles whatever's
        # left.
        run_id="$(echo "$run_json" \
            | jq -r '[.workflow_runs[] | select(.status == "completed")][0].id // empty' \
            2>/dev/null)" || run_id=""
        if [ -z "$run_id" ]; then
            echo "fetch-otp-source: $q matched no completed Build and check run" >&2
            continue
        fi
        artifact_id="$(curl -fsSL "${auth[@]}" \
            "https://api.github.com/repos/erlang/otp/actions/runs/$run_id/artifacts" 2>/dev/null \
            | jq -r '[.artifacts[] | select(.name == "otp_prebuilt" and .expired == false)][0].id // empty' \
            2>/dev/null)" || artifact_id=""
        if [ -z "$artifact_id" ]; then
            echo "fetch-otp-source: run $run_id has no unexpired otp_prebuilt artifact" >&2
            continue
        fi
        echo "fetch-otp-source: fetching otp_prebuilt artifact $artifact_id (run $run_id)" >&2
        curl -fsSL -L "${auth[@]}" \
            "https://api.github.com/repos/erlang/otp/actions/artifacts/$artifact_id/zip" \
            -o "$WORK/prebuilt.zip" 2>/dev/null \
            || { echo "fetch-otp-source: artifact $artifact_id download failed" >&2; continue; }
        unzip -q "$WORK/prebuilt.zip" -d "$WORK/prebuilt" \
            || { echo "fetch-otp-source: artifact $artifact_id unzip failed" >&2; continue; }
        tar xzf "$WORK/prebuilt/otp_src.tar.gz" \
            || { echo "fetch-otp-source: artifact $artifact_id tarball extract failed" >&2; continue; }
        # The artifact's tarball extracts to "otp/" already.
        SRC="otp"
        break
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
    if curl -fsLI -o /dev/null "$archive_url"; then
        echo "fetch-otp-source: falling back to $archive_url" >&2
        if curl -fL "$archive_url" | tar xz; then
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
