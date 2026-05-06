#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

#
# Refresh the vendored target deps under
# apps/awfy_target_runner/deps/{benchee,deep_merge,statistex}/ from
# the host project's resolved Hex versions. Re-applies the dev/test
# strip from PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A.
#
# Idempotent — running with no upstream change is a no-op.
#
# Usage:
#   bin/refresh-target-deps.sh             # show what would change
#   bin/refresh-target-deps.sh --apply     # write the changes
#
# Pre-reqs:
#   * The host project must have resolved deps already; the script
#     copies from ./deps/<name>/ rather than fetching from Hex
#     directly (the host's mix.lock is the version source of truth).
#   * Run from a TLS-current host so the host's `mix deps.get` works
#     normally — vendored copies inherit whatever the host resolved.
#
# Workflow:
#   1. Bump the version constraint in the *root* mix.exs (or just
#      `mix deps.update <name>`).
#   2. `mix deps.get` to update the host's deps tree.
#   3. `bin/refresh-target-deps.sh --apply` to mirror the new sources
#      into the sub-app.
#   4. Verify the sub-app still compiles + tests pass:
#        mix cmd --cd apps/awfy_target_runner mix test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWFY_ROOT="${AWFY_ROOT:-$(dirname "$SCRIPT_DIR")}"
HOST_DEPS="$AWFY_ROOT/deps"
SUBAPP_DEPS="$AWFY_ROOT/apps/awfy_target_runner/deps"

DEPS=(benchee deep_merge statistex)

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  --help|-h)
    sed -n '2,30p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "[refresh-target-deps] unknown flag: $1" >&2
    exit 2
    ;;
esac

[ -d "$HOST_DEPS" ] || {
  echo "[refresh-target-deps] host deps tree missing at $HOST_DEPS — run \`mix deps.get\` first" >&2
  exit 1
}

apply_strip() {
  # Re-apply the dev/test/docs strip per Appendix A. We replace the
  # entire `defp deps do ... end` block with our minimal version,
  # keyed on the dep name. The strip is mechanical — see the
  # vendored mix.exs files for the post-edit shape.
  local name="$1" mix_exs="$2"
  case "$name" in
    benchee)
      python3 - "$mix_exs" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
new_block = '''  # Stripped of dev/test/docs deps per
  # PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A. Mix 1.9 walks the
  # full transitive `deps()` list of every dep regardless of MIX_ENV
  # and `only:`, so dev/test entries trigger Hex registry lookups
  # which cannot succeed when target OTP is built `--without-ssl`.
  # The conditional `:table` branch is also dropped — `:table` is
  # unused on our codepath and re-introduces the same SCM-lookup
  # problem.
  defp deps do
    [
      {:deep_merge, path: "../deep_merge"},
      {:statistex, path: "../statistex"}
    ]
  end'''
src = re.sub(
    r'  defp deps do\n.*?\n  end',
    new_block,
    src,
    count=1,
    flags=re.DOTALL,
)
p.write_text(src)
PY
      ;;
    deep_merge|statistex)
      python3 - "$mix_exs" "$name" <<'PY'
import sys, re, pathlib
p, name = pathlib.Path(sys.argv[1]), sys.argv[2]
src = p.read_text()
ref = "deps/benchee" if name == "deep_merge" else "apps/awfy_target_runner/deps/benchee"
new_block = f'''  # Stripped of dev/test/docs deps per
  # PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A. See {ref}
  # for the full rationale.
  defp deps do
    []
  end'''
src = re.sub(
    r'  defp deps do\n.*?\n  end',
    new_block,
    src,
    count=1,
    flags=re.DOTALL,
)
p.write_text(src)
PY
      ;;
  esac
}

CHANGES=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for name in "${DEPS[@]}"; do
  src="$HOST_DEPS/$name"
  dst="$SUBAPP_DEPS/$name"
  [ -d "$src" ] || {
    echo "[refresh-target-deps] $src missing — host hasn't fetched $name?" >&2
    exit 1
  }

  staging="$WORK/$name"
  cp -R "$src" "$staging"
  apply_strip "$name" "$staging/mix.exs"

  if ! diff -qr "$staging" "$dst" >/dev/null 2>&1; then
    CHANGES=1
    if [ "$APPLY" -eq 1 ]; then
      rm -rf "$dst"
      mv "$staging" "$dst"
      echo "[refresh-target-deps] updated $dst"
    else
      echo "[refresh-target-deps] would update $dst:"
      diff -ruN "$dst" "$staging" | head -40 || true
      echo "..."
    fi
  fi
done

if [ "$CHANGES" -eq 0 ]; then
  echo "[refresh-target-deps] up to date"
elif [ "$APPLY" -ne 1 ]; then
  echo
  echo "[refresh-target-deps] re-run with --apply to write the changes"
  exit 1
fi
