#!/usr/bin/env bash
#
# Drain queued macOS benchmark jobs on the M5 self-hosted runner.
# Runs at the user's leisure: claims one job, runs it to completion,
# then checks the queue for the next, and exits when the queue is
# empty. No daemon, no launchd, no fight with daily work.
#
# Usage:
#   bin/m5-drain.sh                  # drain queue and exit
#   bin/m5-drain.sh --watch          # keep running, grab new jobs as they queue
#   bin/m5-drain.sh --wait-secs 600  # if queue is empty, wait up to N seconds
#                                      for a job before exiting (good for
#                                      "kick off a workflow then start me")
#
# Prereqs:
#   - actions-runner installed at $RUNNER_DIR (default ~/actions-runner)
#   - gh CLI authenticated (`gh auth status`)
#   - run from the awfy repo or with REPO=owner/repo in env

set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
LABEL="${LABEL:-macos-m5}"
REPO="${REPO:-}"
WATCH=false
WAIT_SECS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --watch)     WATCH=true ;;
        --wait-secs) WAIT_SECS="$2"; shift ;;
        --label)     LABEL="$2"; shift ;;
        --repo)      REPO="$2"; shift ;;
        -h|--help)
            sed -n '3,20p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [ -z "$REPO" ]; then
    if remote=$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null); then
        REPO=$(printf '%s\n' "$remote" \
            | sed -E 's#.*github\.com[:/]##; s#\.git$##')
    fi
fi
if [ -z "$REPO" ]; then
    echo "could not auto-detect REPO; pass --repo owner/name or set REPO=" >&2
    exit 2
fi

if [ ! -x "$RUNNER_DIR/run.sh" ]; then
    echo "no actions-runner at $RUNNER_DIR (set RUNNER_DIR= or install per SETUP.md)" >&2
    exit 2
fi

if ! command -v gh >/dev/null; then
    echo "gh CLI not installed (brew install gh)" >&2
    exit 2
fi

echo "[m5-drain] repo=$REPO label=$LABEL runner=$RUNNER_DIR"

# Returns 0 if there's at least one queued job whose required runner labels
# include $LABEL. Walks workflow_runs?status=queued; for each, lists its jobs
# and matches on labels. The double-walk is unavoidable: GH's API doesn't
# expose "list jobs by required label" directly.
has_queued_for_label() {
    local run_ids
    run_ids=$(gh api -X GET "/repos/$REPO/actions/runs" \
        -f status=queued -f per_page=100 \
        --jq '.workflow_runs[].id' 2>/dev/null) || return 1
    [ -z "$run_ids" ] && return 1

    for run_id in $run_ids; do
        if gh api "/repos/$REPO/actions/runs/$run_id/jobs" \
                --jq ".jobs[] | select(.status==\"queued\") | .labels[]" 2>/dev/null \
                | grep -qx "$LABEL"; then
            return 0
        fi
    done
    return 1
}

# Wait up to $WAIT_SECS for a queued job to appear. Returns 0 when found,
# 1 on timeout. Polls every 10s.
wait_for_queued() {
    local deadline=$(( $(date +%s) + WAIT_SECS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if has_queued_for_label; then
            return 0
        fi
        sleep 10
    done
    return 1
}

cd "$RUNNER_DIR"

count=0
while :; do
    if has_queued_for_label; then
        :
    elif $WATCH; then
        echo "[m5-drain] queue empty — watching (Ctrl-C to stop)"
        # In watch mode, ./run.sh --once blocks until a job arrives.
        # That's fine: we want to keep accepting jobs as they queue.
        :
    elif [ "$WAIT_SECS" -gt 0 ]; then
        echo "[m5-drain] queue empty — waiting up to ${WAIT_SECS}s for a job..."
        if ! wait_for_queued; then
            echo "[m5-drain] timeout — exiting (drained $count jobs)"
            exit 0
        fi
    else
        echo "[m5-drain] queue empty — exiting (drained $count jobs)"
        exit 0
    fi

    count=$((count + 1))
    echo "[m5-drain] $(date +%T) claiming job #$count..."
    if ! ./run.sh --once; then
        echo "[m5-drain] runner exited non-zero on job #$count — stopping" >&2
        exit 1
    fi
    echo "[m5-drain] $(date +%T) job #$count complete"
done
