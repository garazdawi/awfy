#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Walk a list of expanded OTP refs, probe gh-pages for what's already
# published, and emit three per-platform JSON arrays of resolved
# target entries plus a small handful of routing booleans.
#
# Inputs:
#   $1                — comma-separated list of fully-expanded OTP
#                       refs (output of bin/expand-otp-refs.sh).
#                       Empty entries are tolerated.
#   env FILL_MODE     — "1" enables the gh-pages skip check; "0"
#                       (or unset) emits every ref into every
#                       platform list it qualifies for.
#   env INPUT_BENCHMARKS — comma-separated benchmark names. When set
#                          AND FILL_MODE=1, the per-platform skip
#                          check looks for `<Bench>.benchee` blobs
#                          rather than just any run-dir.
#   env GITHUB_REPOSITORY — used by the gh-pages contents/tree probes.
#                           Defaults to `owner/repo` parsed from `git
#                           remote get-url origin` for local runs.
#   env GH_TOKEN          — auth for `gh api`. Required for non-public
#                           repos; the standard GHA token works on
#                           public repos.
#   env GITHUB_OUTPUT     — file to append output lines to. If unset,
#                           outputs go to stdout.
#
# Outputs (to GITHUB_OUTPUT or stdout):
#   targets_modern_linux=[…]   — entries that need the modern (OTP ≥ 24,
#                                peer-runner) Linux measure leg.
#   targets_modern_macos=[…]
#   targets_modern_windows=[…]
#   targets_legacy_linux=[…]   — entries that need the legacy (OTP < 24,
#                                target-Elixir bundle) Linux leg.
#   targets_legacy_macos=[…]
#   targets_legacy_windows=[…]
#   targets_legacy_build=[…]    — union by major of the three legacy
#                                 arrays. Drives build-linux-target +
#                                 prep-target-bundle so a fill that
#                                 needs only windows or macos still
#                                 triggers the shared bundle prep
#                                 every legacy measure job consumes.
#   has_modern_linux=true|false   — does targets_modern_linux have
#                                   at least one entry? Used to gate
#                                   the whole measure-linux job.
#   …same six has_* per (mode, platform), plus has_legacy_build…
#
# stderr — `[fill]` decision log and `Resolved …` lines for each ref.
#
# Each entry is a JSON object with the fields the downstream measure
# jobs consume:
#   ref, windows_ref, sha, short, label, major, otp_label,
#   windows_otp_label, elixir, elixir_bundle, commit_timestamp,
#   extra_configure, mode
#
# Why pre-filter per-mode here rather than letting the workflow do
# it via `if: matrix.target.mode == '…'`: GHA evaluates job-level
# `if:` *before* matrix expansion. Naming `matrix.target` in a
# job-level `if:` causes the whole workflow to be rejected at parse
# time. Step-level `if:` does see matrix, but spawning wrong-mode
# runners only to skip every step burns ~30 s per row. Filtering
# once in bash sidesteps both. See PLAN/TARGET_ELIXIR_RUNNER_PLAN.md
# § Follow-ups item 3 for the full discussion.
#
# Per-(ref, platform) skip rule:
#   * FILL_MODE=0 → every platform needs to run for every ref.
#   * FILL_MODE=1, no benchmarks → for each platform, the ref needs
#     that platform's measurement run iff there's no `_<sha10>-test-
#     <plat>-` run-dir on gh-pages.
#   * FILL_MODE=1, benchmarks set → for each platform, the ref needs
#     that platform's run iff any requested benchmark lacks a matching
#     `<Bench>.benchee` blob under that platform's run-dirs. The
#     workflow passes `--benchmarks <list>` to mix awfy.measure so
#     only those benchmarks actually execute. The new run-dir is
#     timestamped separately (publish doesn't merge into existing
#     dirs); the dashboard already groups multiple run-dirs per
#     (sha, platform), so the new datapoint just joins the series.
#
# Why herestring (`<<<`) feeding grep, not `printf|grep`: the pipe
# form trips on SIGPIPE under `set -o pipefail`. When grep matches
# and exits early, printf's next write fails with EPIPE (exit 141),
# pipefail surfaces that as the pipeline's exit, the outer `if ! …`
# flips, and we conclude "platform missing" exactly when it's
# present. Herestring avoids the process pipe entirely — bash writes
# the variable to a temp file fed as grep's stdin, so grep's early
# exit doesn't propagate backwards.

set -euo pipefail

EXPANDED_REFS="${1:?usage: $0 <comma-separated-expanded-refs>}"
FILL_MODE="${FILL_MODE:-0}"
INPUT_BENCHMARKS="${INPUT_BENCHMARKS:-}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  # Local-run fallback: pull `owner/repo` from the origin remote.
  GITHUB_REPOSITORY="$(git remote get-url origin 2>/dev/null \
    | sed -E 's|^git@github\.com:|https://github.com/|; s|\.git$||' \
    | sed -E 's|^https://github.com/||')"
fi

# Memoise erlang/otp's master major across the script — bin/latest-
# master-major.sh always re-fetches, but we only need it once per
# resolve step. See that script for the rationale on why we abort
# on curl failure rather than fall back to a hardcoded number.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_MASTER_MAJOR=""
next_master_major() {
  if [ -z "$_MASTER_MAJOR" ]; then
    _MASTER_MAJOR="$("$SCRIPT_DIR/next-master-major.sh")"
  fi
  echo "$_MASTER_MAJOR"
}

# Determine the OTP major from the (possibly expanded) ref. Used
# downstream to pick the right elixir-otp-XX.zip bundle and to route
# legacy vs modern.
otp_major_for_ref() {
  local r="$1"
  case "$r" in
    OTP-*)
      echo "${r#OTP-}" | cut -d. -f1
      ;;
    master|master:*)
      # `master:<sha>` carries a pinned merge commit but still
      # represents master — the major is master's current major.
      # See bin/expand-otp-refs.sh for the prefix convention.
      next_master_major
      ;;
    maint-*)
      echo "${r#maint-}"
      ;;
    *)
      # Fall back to fetching OTP_VERSION from the resolved SHA;
      # if even that fails (network blip mid-run), use the master
      # major as a final fallback rather than crashing the whole
      # resolve step.
      local sha="$2"
      local v
      v="$(curl -fsSL "https://raw.githubusercontent.com/erlang/otp/$sha/OTP_VERSION" 2>/dev/null \
           | head -1 | cut -d. -f1)"
      if [ -n "$v" ]; then
        echo "$v"
      else
        next_master_major
      fi
      ;;
  esac
}

# Pick a precompiled Elixir release that ships an
# `elixir-otp-<major>.zip` bundle for this OTP. Elixir's support
# window has shifted over time:
#   * 1.14.5 → otp-23, 24, 25
#   * 1.16.3 → otp-24, 25, 26
#   * 1.17.3 → otp-25, 26, 27
#   * 1.18.4 → otp-25, 26, 27 (1.18.5 dropped 26)
#   * 1.19.5 → otp-27, 28
# OTP < 24 has no matching elixir-otp-XX.zip; those targets take the
# bundle-target path (the `apps/awfy_target_runner/` source-built
# Elixir against the target OTP — pinned per-major below).
#
# Single source of truth lives in priv/elixir-for-otp.sh; bench.yml's
# Pin Elixir steps, install-otp-source-mac.sh's post-build install,
# and measure-all-macos.sh's modern-path PATH all read the same file.
SCRIPT_DIR_FOR_ELIXIR_LOOKUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_version_for_major() {
  "$SCRIPT_DIR_FOR_ELIXIR_LOOKUP/../priv/elixir-for-otp.sh" "$1"
}

# Map an OTP major to the OTP suffix on the elixir-otp-XX.zip bundle
# to download. Identity for OTPs Elixir has already released a bundle
# for, but caps at 28 for OTPs newer than that (right now: master =
# OTP 29). The elixir-otp-29 bundle ships only on Elixir's
# `main-latest` rolling release; the tagged `v1.19.5` doesn't include
# it. Bundles are forward-compatible across one major so an
# elixir-otp-28 binary runs fine on an OTP 29 host. Bump the cap when
# Elixir releases a tagged v1.20-or-later that ships otp-29.
elixir_bundle_major_for_major() {
  case "$1" in
    22|23|24|25|26|27|28) echo "$1" ;;
    *) echo "28" ;;
  esac
}

# In fill mode, list run-dir names already on gh-pages so the per-ref
# loop can skip refs that have all expected platforms covered. Run-
# dirs are named `<ts>_otp<release>_elixir<version>_<sha10>-test-
# <platform>-<arch>-<flavor>` — see Awfy.Measure.Helpers.run_dir/5.
# We grep for `_<sha10>-test-` so dashboard HTML/JS in the repo root
# doesn't get mistaken for run-dirs.
#
# When INPUT_BENCHMARKS is set, also fetch every `*.benchee` blob
# path on gh-pages in one `git/trees?recursive=1` call. That powers
# the per-benchmark variant of the skip check below. The recursive
# tree API returns `truncated: true` if the repo has too many blobs
# to fit in one page; we check and warn (skip-check disabled, all
# refs re-run).
#
# `gh api ... --paginate` follows Link-header pagination so this
# works past the API's default 100-entry page. 2>/dev/null + `|| true`
# makes a missing gh-pages branch (first run, no publish yet) a no-op
# rather than a hard failure.
EXISTING_RUNDIRS=""
EXISTING_BENCHEES=""
if [ "$FILL_MODE" = "1" ]; then
  EXISTING_RUNDIRS="$(gh api \
    "repos/${GITHUB_REPOSITORY}/contents?ref=gh-pages" \
    --paginate --jq '.[].name' 2>/dev/null \
    | grep -E '_[0-9a-f]{10}-test-' || true)"
  count="$(grep -c . <<<"$EXISTING_RUNDIRS" || true)"
  echo "[fill] gh-pages has $count existing run-dirs" >&2

  if [ -n "$INPUT_BENCHMARKS" ]; then
    tree_json="$(gh api \
      "repos/${GITHUB_REPOSITORY}/git/trees/gh-pages?recursive=1" \
      2>/dev/null || echo '{}')"
    if [ "$(printf '%s' "$tree_json" | jq -r '.truncated // false')" = "true" ]; then
      echo "::warning::gh-pages tree exceeds API page limit; benchmark-targeted skip disabled" >&2
    else
      EXISTING_BENCHEES="$(printf '%s' "$tree_json" \
        | jq -r '.tree[]? | select(.type == "blob") | .path' \
        | grep -E '\.benchee$' || true)"
      bcount="$(grep -c . <<<"$EXISTING_BENCHEES" || true)"
      echo "[fill] gh-pages has $bcount .benchee blobs" >&2
    fi
  fi
fi

# Per-(mode, platform) collectors. Modern and legacy entries land in
# the same intermediate platform array (so the per-ref skip logic can
# share state); we partition by mode at the end via jq for the final
# emitted outputs.
linux_entries="["
macos_entries="["
windows_entries="["
sep_linux=""
sep_macos=""
sep_windows=""

# Track per-(mode, platform) counts so we can emit `has_modern_*` /
# `has_legacy_*` booleans. The workflow uses these to skip whole jobs
# when their mode has no targets at all — needed because GHA happily
# spins up a job that ends up with an empty matrix expansion, then
# fails at `fromJson("[]")` time when no rows materialise.
n_modern_linux=0;  n_modern_macos=0;  n_modern_windows=0
n_legacy_linux=0;  n_legacy_macos=0;  n_legacy_windows=0

for raw in $(echo "$EXPANDED_REFS" | tr ',' ' '); do
  raw="$(echo "$raw" | xargs)"
  [ -z "$raw" ] && continue
  ref="$raw"

  # `master:<sha>` is the master-history form (per
  # bin/expand-otp-refs.sh): each merge commit on master since the
  # cutoff becomes one row, but all share otp_label="master" so the
  # dashboard's existing master column collects them (latest wins
  # for display; meta.json.git.sha preserves the per-merge identity
  # for a future history-timeline view). Strip the prefix here; the
  # SHA is already pinned so we skip the `git ls-remote` lookup the
  # other refs do.
  case "$ref" in
    master:*)
      sha="${ref#master:}"
      ;;
    *)
      # Resolve to a commit SHA. Annotated tags (which is how OTP
      # releases are tagged) need `^{}` to dereference the tag object to
      # the commit it points at; lightweight tags and branches return
      # empty for `^{}` so fall back to the plain ref. Without this, the
      # SHA below is the tag object itself, which then 404s against the
      # commits API.
      sha="$(git ls-remote https://github.com/erlang/otp.git "$ref^{}" | head -1 | cut -f1)"
      if [ -z "$sha" ]; then
        sha="$(git ls-remote https://github.com/erlang/otp.git "$ref" | head -1 | cut -f1)"
      fi
      ;;
  esac

  if [ -z "$sha" ]; then
    echo "::error::could not resolve ref '$ref' on erlang/otp" >&2
    exit 1
  fi
  short="${sha:0:10}"
  label="${short}-test"
  major="$(otp_major_for_ref "$ref" "$sha")"

  # Per-(ref, platform) need flags. In FILL_MODE, reflect what's
  # missing on gh-pages; outside fill, default to 1 so every leg runs.
  need_linux=1
  need_macos=1
  need_windows=1
  if [ "$FILL_MODE" = "1" ]; then
    for plat in linux macos windows; do
      plat_missing=1
      if [ -n "$INPUT_BENCHMARKS" ] && [ -n "$EXISTING_BENCHEES" ]; then
        # All requested benchmarks present for this platform?
        plat_missing=0
        IFS=',' read -ra benches <<<"$INPUT_BENCHMARKS"
        for b in "${benches[@]}"; do
          if ! grep -qE "_${short}-test-${plat}-[^/]+/${b}\.benchee$" \
                <<<"$EXISTING_BENCHEES"; then
            plat_missing=1
            break
          fi
        done
      else
        # Any run-dir present for this platform?
        if grep -q "_${short}-test-${plat}-" <<<"$EXISTING_RUNDIRS"; then
          plat_missing=0
        fi
      fi
      case "$plat" in
        linux)   need_linux=$plat_missing ;;
        macos)   need_macos=$plat_missing ;;
        windows) need_windows=$plat_missing ;;
      esac
    done
    if [ "$need_linux" = "0" ] && [ "$need_macos" = "0" ] && [ "$need_windows" = "0" ]; then
      echo "[fill] $ref ($short) already complete on gh-pages — skipping" >&2
      continue
    fi
    missing=""
    [ "$need_linux"   = "1" ] && missing="${missing} linux"
    [ "$need_macos"   = "1" ] && missing="${missing} macos"
    [ "$need_windows" = "1" ] && missing="${missing} windows"
    echo "[fill] $ref ($short) needs:${missing}" >&2
  fi

  elixir="$(elixir_version_for_major "$major")"
  elixir_bundle="$(elixir_bundle_major_for_major "$major")"

  # Commit timestamp — the dashboard plots each run against this, so
  # benchmarking a year-old OTP today shouldn't make every old release
  # cluster at "now". gh api with --jq still writes the JSON error
  # body to stdout on 4xx responses (and returns exit 0 for some of
  # them), so pipe through local jq with a `// ""` default to cleanly
  # fall back to empty on any failure.
  commit_timestamp="$(gh api "repos/erlang/otp/commits/$sha" 2>/dev/null \
    | jq -r '.commit.committer.date // ""' 2>/dev/null \
    || echo "")"

  # OTP < 24's crypto NIF uses APIs OpenSSL 3 removed
  # (RSA_get0_crt_params, EVP_MD_meth_new, …). The GHA Ubuntu image
  # ships only OpenSSL 3, so for those targets drop ssl/ssh/crypto
  # entirely. OTP 24.0/.1 referenced FIPS_mode (also removed in
  # OpenSSL 3) but the awfy patch
  # `patches/OTP-24/01-pkey-fips-mode-openssl3.patch` stubs it out so
  # 24.0/.1 build cleanly against OpenSSL 3 too — which matters
  # because mix needs crypto to talk to hex.
  extra_configure=""
  if [ "$major" -lt 24 ] 2>/dev/null; then
    extra_configure="--without-ssl"
    mode="legacy"
  else
    mode="modern"
  fi

  # otp_label is what the dashboard plots on its x axis. We carry the
  # full resolved version ("28.5.4", "29.0-rc3") for tagged refs so
  # the snapshot legend is unambiguous — the dashboard buckets by
  # major for grouping. "master" / "maint" / "maint-*" pass through
  # verbatim so they land at the right edge of the trend chart;
  # without bare `maint` here it falls into the catch-all and gets
  # relabelled as its resolved major (28), folding into the 28.x
  # lineage instead of getting its own dashboard slot.
  #
  # `master:<sha>` (master-history form) collapses to "master" too so
  # every merge run lands in the same dashboard column. The per-merge
  # identity is preserved in meta.json.git.sha + the run-dir's
  # SHA-bearing label; a future master-history view will read those
  # to plot the per-merge timeline.
  case "$ref" in
    master:*)             otp_label="master" ;;
    master|maint|maint-*) otp_label="$ref" ;;
    OTP-*)                otp_label="${ref#OTP-}" ;;
    *)                    otp_label="$major" ;;
  esac

  # Windows installer ref. measure-windows for OTP ≥ 24 hits patch-
  # version installers directly (every OTP ≥ 24 patch publishes one).
  # For OTP < 24 the patch installers don't exist (e.g. OTP-21.0.9 has
  # no otp_win64_21.0.9.exe), but the function-release installer
  # always does — both on github.com/erlang/otp/releases (≥ 21.0) and
  # on erlang.org/download (≥ 17.0). So we map the legacy ref down to
  # its X.Y prefix here so install-otp-windows.ps1 can find a working
  # installer.
  case "$ref" in
    OTP-*) rest="${ref#OTP-}" ;;
    *)     rest="" ;;
  esac
  xy="$(echo "$rest" | cut -d. -f1,2)"
  if [ "$mode" = "legacy" ] && [ -n "$xy" ]; then
    windows_ref="OTP-$xy"
    # windows_otp_label is what the dashboard plots for the Windows
    # leg specifically — must match the binary that actually runs
    # (the function release, e.g. "21.0"), not the patch label
    # "21.0.9" we use everywhere else. Without this, OTP-21.0.9's
    # Windows row claims it ran 21.0.9 while really running 21.0.
    windows_otp_label="$xy"
  elif [[ "$ref" == master:* ]]; then
    # `master:<sha>` (master-history form): install-otp-windows.ps1
    # walks `repos/erlang/otp/actions/runs?head_sha=<sha>` for the
    # otp_win32_installer artifact. Pass the bare SHA so the
    # head_sha filter matches. When the artifact is missing
    # (upstream skips the installer build on no-C-change merges)
    # the install step exits with skipped=true and downstream
    # measure steps gate off it — Windows is opportunistic for
    # master commits.
    windows_ref="$sha"
    windows_otp_label="master"
  else
    windows_ref="$ref"
    windows_otp_label="$otp_label"
  fi

  entry="{\"ref\":\"$ref\",\"windows_ref\":\"$windows_ref\",\"sha\":\"$sha\",\"short\":\"$short\",\"label\":\"$label\",\"major\":\"$major\",\"otp_label\":\"$otp_label\",\"windows_otp_label\":\"$windows_otp_label\",\"elixir\":\"$elixir\",\"elixir_bundle\":\"$elixir_bundle\",\"commit_timestamp\":\"$commit_timestamp\",\"extra_configure\":\"$extra_configure\",\"mode\":\"$mode\"}"

  if [ "$need_linux" = "1" ]; then
    linux_entries="${linux_entries}${sep_linux}${entry}"
    sep_linux=","
    if [ "$mode" = "modern" ]; then n_modern_linux=$((n_modern_linux+1)); else n_legacy_linux=$((n_legacy_linux+1)); fi
  fi
  if [ "$need_macos" = "1" ]; then
    macos_entries="${macos_entries}${sep_macos}${entry}"
    sep_macos=","
    if [ "$mode" = "modern" ]; then n_modern_macos=$((n_modern_macos+1)); else n_legacy_macos=$((n_legacy_macos+1)); fi
  fi
  if [ "$need_windows" = "1" ]; then
    windows_entries="${windows_entries}${sep_windows}${entry}"
    sep_windows=","
    if [ "$mode" = "modern" ]; then n_modern_windows=$((n_modern_windows+1)); else n_legacy_windows=$((n_legacy_windows+1)); fi
  fi

  if [ "$mode" = "legacy" ]; then
    echo "Resolved $ref → $sha (OTP $major, bundle-target mode)" >&2
  else
    echo "Resolved $ref → $sha (OTP $major, peer-runner mode, Elixir $elixir)" >&2
  fi
done

linux_entries="${linux_entries}]"
macos_entries="${macos_entries}]"
windows_entries="${windows_entries}]"

bool() { [ "$1" -gt 0 ] && echo true || echo false; }

# Partition each platform's entries into per-mode arrays via jq so
# each measure-* job's matrix expands directly to the rows it cares
# about — see the header comment for why we can't filter inline in
# the workflow.
filter_mode() {
  jq -c --arg m "$2" '[.[] | select(.mode == $m)]' <<<"$1"
}

modern_linux="$(filter_mode   "$linux_entries"   modern)"
modern_macos="$(filter_mode   "$macos_entries"   modern)"
modern_windows="$(filter_mode "$windows_entries" modern)"
legacy_linux="$(filter_mode   "$linux_entries"   legacy)"
legacy_macos="$(filter_mode   "$macos_entries"   legacy)"
legacy_windows="$(filter_mode "$windows_entries" legacy)"

# Union of all legacy entries deduplicated by major. Drives
# build-linux-target + prep-target-bundle, which every legacy
# measure-* job depends on (linux directly, macos/windows via the
# extracted bundle). Without this, a fill that needs only legacy
# windows for major 21 leaves has_legacy_linux=false → prep is
# skipped → measure-windows-target is silently skipped too.
legacy_build="$(jq -cn \
  --argjson a "$legacy_linux" \
  --argjson b "$legacy_macos" \
  --argjson c "$legacy_windows" \
  '($a + $b + $c) | unique_by(.major)')"
n_legacy_build="$(jq 'length' <<<"$legacy_build")"

{
  echo "targets_modern_linux=${modern_linux}"
  echo "targets_modern_macos=${modern_macos}"
  echo "targets_modern_windows=${modern_windows}"
  echo "targets_legacy_linux=${legacy_linux}"
  echo "targets_legacy_macos=${legacy_macos}"
  echo "targets_legacy_windows=${legacy_windows}"
  echo "targets_legacy_build=${legacy_build}"
  echo "has_modern_linux=$(bool $n_modern_linux)"
  echo "has_modern_macos=$(bool $n_modern_macos)"
  echo "has_modern_windows=$(bool "$n_modern_windows")"
  echo "has_legacy_linux=$(bool "$n_legacy_linux")"
  echo "has_legacy_macos=$(bool "$n_legacy_macos")"
  echo "has_legacy_windows=$(bool "$n_legacy_windows")"
  echo "has_legacy_build=$(bool "$n_legacy_build")"
} >> "$OUTPUT"

echo "modern linux:   $modern_linux"   >&2
echo "modern macos:   $modern_macos"   >&2
echo "modern windows: $modern_windows" >&2
echo "legacy linux:   $legacy_linux"   >&2
echo "legacy macos:   $legacy_macos"   >&2
echo "legacy windows: $legacy_windows" >&2
echo "legacy build:   $legacy_build"   >&2
