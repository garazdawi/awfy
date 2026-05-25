#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0
#
# Expand a workflow `otp_refs` input string into a flat comma-separated
# list of full OTP refs, ready for the resolve step to walk.
#
# Inputs:
#   $1            — the raw INPUT_REFS string. One of:
#                    * `all` / `fill`                    — the per-
#                      function-release backfill set (see below).
#                    * `<csv of refs and shorthand>`     — passed
#                      through; each token is run through
#                      `expand_ref` to fill in patch versions.
# Outputs:
#   stdout        — final expanded refs as a single comma-separated
#                   line, e.g. `OTP-21.3.8.24,OTP-28.5,master`.
#   stderr        — diagnostics (the chosen TABLE path, expansion log).
#   exit non-zero — failed to expand a shorthand, missing dependency,
#                   or curl failure on otp_versions.table.
#
# Usage:
#   ./bin/expand-otp-refs.sh "$INPUT_REFS"
#
# `all` / `fill` expansion algorithm (per-function-release):
#
#   For each `OTP-X.Y` two-component entry in otp_versions.table
#   (newest-first), the maintenance tip of that line is the newest
#   version with that prefix.
#     * If X.Y is the major's *active* maint branch — recognised here
#       as the first X.Y prefix encountered for that major in
#       newest-first order — take whatever the tip is, including
#       4-component security backports (e.g. OTP-21.3 → OTP-21.3.8.24).
#     * If X.Y is a grey/superseded line, stop at the last 3-component
#       patch (e.g. OTP-23.2 → OTP-23.2.7), skipping the OTP-23.2.7.x
#       sub-branch which is on a deeper branch off OTP-23.2.7
#       specifically rather than continuing maint-23.2.
#
#   See https://erlang.org/download/otp_versions_tree.html for the
#   branch structure. This rule visually corresponds to "Maintenance
#   branches of old releases" + "the main track including the
#   maintenance branch of the current release", excluding "Other
#   branches".
#
#   `sort -V` orders the output by version (oldest first) so the
#   trend chart's category axis populates left-to-right. We append
#   `maint` (next function release of current major) and `master`
#   (next major) at the end so they land at the right edge of every
#   chart, followed by `master:<sha>` rows — one per merge commit on
#   master since OTP-29.0 — so the dashboard records a data point
#   per landed feature. The merge SHAs flow through the same fill
#   skip check, so subsequent fills are cheap: only new merges land.
#
# `master_history` expansion: emit ONLY the master merge commits
# (no maint-tips). Use this from `workflow_dispatch` when the
# operator wants to track master without re-running stable
# releases.
#
# The history window is bounded by both OTP-29.0 (release floor,
# the start of master-merge tracking) and a rolling 3-month date
# window — once OTP-29.0 itself slips past 3 months ago, the date
# is what matters. `bin/resolve-fill-needs.sh` further caps the
# *needed* subset at 50 SHAs per run so a freshly-empty gh-pages
# doesn't queue hundreds of measure jobs in one matrix.

set -euo pipefail

INPUT_REFS="${1:?usage: $0 <comma-separated-refs-or-all-or-fill>}"

TABLE="$(mktemp)"
trap 'rm -f "$TABLE"' EXIT
curl -fsSL --max-time 15 \
  https://raw.githubusercontent.com/erlang/otp/master/otp_versions.table \
  > "$TABLE"

# Expand a single shorthand token to a full OTP tag.
#
#   - "21".."29"/"30" → newest entry with that major prefix in
#                       otp_versions.table. For old majors this
#                       resolves to a 4-component maint-X.Y tip
#                       (e.g. 21 → OTP-21.3.8.24); for the current
#                       major a 3-component patch.
#   - "X.Y"           → newest entry with that exact minor prefix
#                       (the maint-X.Y tip).
# Anything else (full tag, "master", "maint-*", SHA) passes through
# verbatim.
#
# `grep -m1` stops grep itself at the first match, so the downstream
# `awk` pipe never sees a closed-write SIGPIPE — important under
# `set -o pipefail`, which would otherwise turn the SIGPIPE into a
# nonzero pipeline exit on shorthand like "22.3" that matches many
# lines.
expand_ref() {
  local r="$1"
  case "$r" in
    2[0-9]|3[0-9])
      # `|| true` so a grep no-match (e.g. shorthand 35 against a
      # table with no 35.x entries) returns an empty string instead
      # of tripping `set -o pipefail` + `set -e` and tearing down
      # the script before the "could not expand" diagnostic below
      # gets a chance to print.
      grep -m1 -E "^OTP-$r\\.[0-9.]+ " "$TABLE" | awk '{print $1}' || true
      ;;
    [0-9][0-9].[0-9]|[0-9][0-9].[0-9][0-9])
      local re="OTP-${r//./\\.}"
      grep -m1 -E "^${re}(\\.|[ ])" "$TABLE" | awk '{print $1}' || true
      ;;
    *) echo "$r" ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Format `master_history` enumeration output (one SHA per line) into
# the comma-separated `master:<sha>` ref form `resolve-fill-needs.sh`
# strips back to a bare SHA + sets otp_label="master" for. The
# prefix is the explicit signal "this SHA came from master's
# merge history" — without it, a bare 40-char SHA would fall into
# the catch-all and get labeled by its resolved major (e.g. "30"),
# splitting one bench column per merge.
#
# `AWFY_ENUMERATE_MERGES_SH` env var overrides the enumerate-script
# path so tests can stub it without going to network.
#
# `AWFY_MERGES_SINCE_DATE` (defaulting to "3 months ago") narrows
# the enumerate window via `git log --since=`. Keeps the master
# timeline focused on recent activity — older measurements stay
# in gh-pages and the dashboard, but new fill runs no longer
# include the entire OTP-29.0..master backlog as candidates.
master_history_refs() {
  local since="${1:-OTP-29.0}"
  local script="${AWFY_ENUMERATE_MERGES_SH:-$SCRIPT_DIR/enumerate-master-merges.sh}"
  AWFY_MERGES_SINCE_DATE="${AWFY_MERGES_SINCE_DATE:-3 months ago}" \
    "$script" "$since" \
    | awk 'NF { print "master:" $0 }' \
    | tr "\n" "," \
    | sed 's/,$//'
}

if [ "$INPUT_REFS" = "master_history" ]; then
  refs="$(master_history_refs OTP-29.0)"
  if [ -z "$refs" ]; then
    echo "::warning::master_history produced no refs (no merges since OTP-29.0?)" >&2
    exit 0
  fi
  echo "$refs"
  exit 0
fi

if [ "$INPUT_REFS" = "all" ] || [ "$INPUT_REFS" = "fill" ]; then
  # One tip per major: the latest patch on the active (newest)
  # function-release line. Older function-release lines (e.g.
  # OTP-21.0/21.1/21.2) stop getting backports once OTP-21.3 ships,
  # so plotting them next to OTP-21.3.8.24 reflects backport
  # bookkeeping (some fixes landed in 21.3 only) rather than the
  # runtime trend. Collapsing to one tip per major (e.g.
  # OTP-21.3.8.24, OTP-22.3.4.27, OTP-26.2.5.20) gives an apples-to-
  # apples timeline across majors.
  CANDIDATES="$(awk '
    # Pass 1: collect 2-component OTP-X.Y function-release prefixes
    # for majors X >= 20.
    FNR == NR {
      if ($1 ~ /^OTP-[0-9]+\.[0-9]+$/) {
        rest = $1; sub(/^OTP-/, "", rest)
        split(rest, parts, ".")
        if (parts[1] >= 20) prefixes[$1] = 1
      }
      next
    }
    # Pass 2 (newest-first): for each tag, locate its X.Y prefix.
    # The first prefix seen per major is the active maintenance
    # line; keep only the first matching tag for that active line.
    {
      tag = $1
      if (tag ~ /-rc[0-9]/) next
      rest = tag; sub(/^OTP-/, "", rest)
      split(rest, parts, ".")
      if (parts[1] < 20) next
      major = parts[1]
      tag_prefix = ""
      for (pre in prefixes) {
        if (tag == pre || index(tag, pre ".") == 1) {
          tag_prefix = pre
          break
        }
      }
      if (tag_prefix == "") next
      if (!(major in active_for)) active_for[major] = tag_prefix
      if (tag_prefix != active_for[major]) next
      if (major in tip_for) next
      tip_for[major] = tag
    }
    END {
      # OTP-20 override: source-dist tarballs only exist for OTP-20.3
      # itself; the .X.Y security backports were never published as
      # src dists. Pin OTP-20 to its bare function-release tag.
      tip_for[20] = "OTP-20.3"
      for (m in tip_for) print tip_for[m]
    }
  ' "$TABLE" "$TABLE" | sort -V | tr "\n" "," )"
  # `maint` is upstream's pre-release branch for the next function
  # release of the current major; pairing it with `master` (next
  # major) gives two forward-looking trend points alongside the
  # released maint tips.
  #
  # Then append every merge commit on master since OTP-29.0 as a
  # `master:<sha>` row. Each is resolved by resolve-fill-needs.sh to
  # a label-distinct run-dir but kept under otp_label="master" so the
  # existing trend chart's master column still renders the latest;
  # the per-merge data lives in meta.json.git.sha for a future
  # master-history view to consume (PLAN/INFRA_REFACTOR.md follow-up).
  # Fill mode's gh-pages skip check means only NEW merges land each
  # run; first invocation re-measures everything since the cutoff,
  # subsequent invocations only catch up on what landed since.
  HISTORY="$(master_history_refs OTP-29.0)"
  if [ -n "$HISTORY" ]; then
    echo "${CANDIDATES}maint,master,${HISTORY}"
  else
    echo "${CANDIDATES}maint,master"
  fi
  exit 0
fi

# Comma-separated input — expand each token through expand_ref.
out=""
sep=""
for raw in $(echo "$INPUT_REFS" | tr ',' ' '); do
  raw="$(echo "$raw" | xargs)" # trim whitespace
  ref="$(expand_ref "$raw")"
  if [ -z "$ref" ]; then
    echo "could not expand shorthand '$raw'" >&2
    exit 1
  fi
  out="${out}${sep}${ref}"
  sep=","
done
echo "$out"
