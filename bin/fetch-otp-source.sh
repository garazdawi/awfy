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
#      for every commit. Skips when GH_TOKEN unset or API yields
#      no run / no artifact (expired, run still in progress, etc).
#   4. github.com/erlang/otp/archive/<sha>.tar.gz
#      — universal fallback, raw source (no prebuilt beams, no
#      generated configure — caller must run `./otp_build autoconf`).
#
# All four outcomes leave $WORK_DIR/otp/ as the canonical source dir.
# Optional GH_TOKEN env var enables path 3 (a personal token or
# GITHUB_TOKEN both work; the artifact is public-readable).

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
        run_id="$(echo "$run_json" \
            | jq -r '[.workflow_runs[] | select(.conclusion == "success")][0].id // empty' \
            2>/dev/null)" || run_id=""
        if [ -z "$run_id" ]; then
            echo "fetch-otp-source: $q matched no successful Build and check run" >&2
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

if [ -z "$SRC" ]; then
    echo "fetch-otp-source: fetching erlang/otp@$SHA via /archive (raw source)" >&2
    curl -fL "https://github.com/erlang/otp/archive/$SHA.tar.gz" | tar xz
    SRC="otp-$SHA"
fi

# Canonicalise to $WORK/otp regardless of which path produced the source.
if [ "$SRC" != "otp" ]; then
    rm -rf "$WORK/otp"
    mv "$WORK/$SRC" "$WORK/otp"
fi

# Tidy up artefact-fetch leftovers so a downstream tarball of $WORK
# doesn't ship them.
rm -rf "$WORK/prebuilt" "$WORK/prebuilt.zip"
