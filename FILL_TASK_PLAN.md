# Fill Task Plan — `mix awfy.fill`, cross-platform backfill

Replaces the GHA-self-hosted-runner pattern (currently `bin/m5-drain.sh`)
with a cross-platform Mix task that reads the `gh-pages` branch,
computes which OTP commits are missing results for the current
platform, and runs them locally. Same idea works on the M5, on a
Windows VM, on a Linux ARM box — any machine with the awfy repo
checked out and `mix` available.

## Goal

Decouple non-Linux platforms from the cloud workflow's matrix
gating. Linux remains the cadence (daily cron in `bench.yml`,
push to `gh-pages`). Every other platform "fills in" against
that schedule on its own clock — including weeks-late backfills
when the M5 was off.

## Design

`mix awfy.fill` (no auto-push):

1. Detect platform via `:os.type/0` + `:erlang.system_info(:system_architecture)`.
   Yields `macos-arm64`, `linux-x86_64`, `linux-arm64`, `windows-x86_64`, etc.
2. Ensure a worktree of `gh-pages` at `_pages/` (fetch + reset to
   `origin/gh-pages`, or create orphan branch on first run).
3. Walk `_pages/<run-dir>/` directories, parse the run-dir name to
   extract `(otp_sha, platform, flavor)`. Run-dir naming is already
   regular: `<ts>_otp<release>_elixir<version>_<otp_short>-<os>-<arch>-<flavor>`.
4. Compute the universe of OTP SHAs as the union across all platforms
   (so Linux's daily run becomes the de-facto schedule without
   hard-coding "Linux is the schedule").
5. Diff: which `(current_platform, jit | emu)` are missing for each
   SHA. Newest-SHA-first ordering.
6. For each missing entry:
   - Install OTP via `bin/install-otp-source.sh` (Unix) or
     `bin/install-otp-windows.ps1` (Windows). Both are
     content-addressed by SHA, so re-runs short-circuit.
   - Spawn a child `mix` subprocess with `PATH=<otp-prefix>/bin:$PATH`,
     `MIX_BUILD_PATH=_build/<otp-sha>` (per-SHA hermetic build tree),
     `ERL_FLAGS=-emu_flavor emu` for the emu flavor.
   - Child runs `mix local.hex && mix local.rebar && mix deps.get && mix compile && mix awfy.measure --label …`.
   - Move resulting run-dirs into `_pages/`.
7. Regenerate the dashboard (`mix awfy.compare --out _pages`).
8. Commit `_pages/` locally. **Never auto-push** — operator runs
   `git -C _pages push origin gh-pages` after reviewing.

## CLI

```
mix awfy.fill                      # find missing SHAs, run them, commit locally
mix awfy.fill --max 3              # cap N runs per invocation
mix awfy.fill --since 2026-04-01   # only SHAs newer than this date
mix awfy.fill --shas abc,def       # explicit SHA list, skip gh-pages query
mix awfy.fill --dry-run            # show what would run, do nothing
mix awfy.fill --platform linux-x86_64
                                    # override platform detection
mix awfy.fill --flavors jit        # subset of {jit, emu}
mix awfy.fill --pages-dir <path>   # alternate gh-pages worktree path
```

## Workflow simplification (paired change)

When this task lands, `bench.yml` drops the `measure-macos` job
entirely. macOS becomes a pure local concern. The cloud workflow
publishes Linux + Windows results immediately; macOS results join
on the next dashboard rebuild (which the fill task triggers).

Windows initially stays in the cloud workflow (Terraform-managed
ephemeral `c6i.4xlarge` + Windows). If cloud spend ever becomes
annoying, Windows could move to fill-driven from a long-lived EC2
/ on-prem Windows box — the task already supports
`--platform windows-x86_64`, no code change needed.

## Why a Mix task and not the current bash script

- **Cross-platform** without a parallel `.ps1` for Windows: `mix`
  itself runs everywhere, `:os.type/0` gives precise dispatch.
- **Reuses existing code**: `Awfy.Compare.Data` already knows how to
  read run dirs; same module backs the dashboard generation; no
  duplication of the meta-parsing logic.
- **Testable**: orchestration logic (compute-missing, diff against
  expected matrix, …) is testable in plain ExUnit, doesn't need
  shell harness.
- **Same ergonomics as the rest of awfy**: `mix awfy.measure`,
  `mix awfy.compare`, `mix awfy.preflight`, `mix awfy.fill` —
  consistent verbs.

## Tradeoffs

- **No GHA workflow logs for fill runs.** The task's stdout becomes
  the log; capture to a file if you want history (`mix awfy.fill
  | tee fill.log`). Acceptable since fill runs are interactive.
- **No `gh auth` required** for the read path (gh-pages is a public
  branch fetched via plain git). Push requires whatever auth the
  user already has on the M5 — typically a GitHub deploy key or
  `gh auth login`.
- **Reimplements ~50 lines** of "what's missing" logic that GHA's
  matrix would have handled. Acceptable — the logic is small and
  shared across all non-Linux platforms.

## Open questions

1. ~~Where does `_pages/` live in `.gitignore`?~~ — landed
   (`.gitignore` includes `_pages/` and `_fill_results/`).
2. **OTP install caching across SHAs.** The installer scripts are
   content-addressed by SHA; running the task twice for the same
   SHA reuses the cached install. But the cache grows over time
   (~200 MB per SHA). Add a `--prune-otp-older-than <date>` flag
   in v2 if disk pressure becomes real.
3. **Subprocess output handling.** A 5-minute child `mix awfy.measure`
   emits a lot of output. Currently the task uses `System.cmd` which
   buffers — long fills look silent for minutes, then dump everything
   on completion. Switch to `Port.open` with `:stream` (or
   `IO.stream`) before this becomes annoying in practice.
4. **Concurrent fills.** If the user has two machines and both run
   `mix awfy.fill` at the same time, they could pick the same SHA
   for the same platform (rare since each machine is a different
   platform, but possible if user runs on two Linux boxes). Skip
   for v1; document "one fill at a time per platform" as the
   discipline.
5. **What if `mix awfy.compare` fails on partial data?** Currently
   the task aborts if any benchmark verifies false; need to confirm
   the same fail-soft path works when fill encounters a regression
   that breaks verification. Likely just requires letting `compare`
   skip-and-warn rather than raise on missing benchmarks.

## Sequence

1. ~~Add `_pages/` to `.gitignore`.~~
2. ~~Implement `Mix.Tasks.Awfy.Fill` and break out parsing /
   orchestration into testable helpers.~~ (Pure logic in
   `Awfy.Fill.Diff`, tested in `test/fill/diff_test.exs`.)
3. ~~Wire `_fill_results/` as a temp landing area before moving
   into `_pages/` (keeps the worktree clean if a run fails partway).~~
4. **Pending**: spike `mix awfy.fill --dry-run` against a populated
   gh-pages, validate the SHA-diff math end-to-end. (Blocked on
   first cloud Linux run populating gh-pages, or a manual
   `--shas <sha>` shakeout.)
5. **Pending**: end-to-end test — drop one run-dir from a local
   gh-pages copy, confirm `mix awfy.fill --shas <that-sha>`
   reproduces it.
6. ~~Update `SETUP.md` to replace the m5-drain section with the fill
   task section. Delete `bin/m5-drain.sh`.~~
7. ~~Update `bench.yml` to drop the `measure-macos` job (the macOS
   leg becomes pure local-fill).~~

## Why not …

- **Auto-push from the task** — pushing to `gh-pages` is
  externally-visible; let the operator review the local commit
  before publishing. Trivial extra step (`git -C _pages push`),
  meaningfully safer.
- **Drive the fill from a GHA workflow** — defeats the point. The
  whole reason to build this is so non-Linux platforms don't need
  GHA orchestration.
- **Use a manifest file in `gh-pages` instead of walking run-dirs** —
  a separate manifest can drift from the actual run-dir contents.
  Walking the tree is the source of truth; <50 ms even on a populated
  branch. Add a manifest if the dashboard generation ever wants one.
- **Always keep `_pages/` as a worktree** — checking out a foreign
  branch into the main repo's worktree is fragile. Using a
  separate worktree path keeps the master branch's working tree
  clean.
