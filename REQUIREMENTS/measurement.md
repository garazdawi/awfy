# Measurement — Requirements

The measurement pipeline takes an OTP ref (release tag, branch, or
master merge SHA), produces benchmark results, and publishes them
to gh-pages. This file says *what* the pipeline must do, not how
it's wired together — that's `ARCHITECTURE.md`.

See also: [Platforms](platforms.md), [Infrastructure](infrastructure.md).

## Triggers

The bench workflow shall accept three triggers:

1. **`push`** — minimal smoke matrix (one ref per code path) so a
   dashboard or workflow change is exercised end-to-end.
2. **`schedule`** — periodic catch-up against gh-pages. Defaults to
   `otp_refs=fill`.
3. **`workflow_dispatch`** — operator-driven with explicit
   `otp_refs` input (`fill`, `all`, `master_history`, or a CSV of
   refs/shorthands).

A scheduled fill firing while a `workflow_dispatch` fill is
in-flight shall queue (not race). Push smoke runs are independent
of fills.

## Ref expansion

The `otp_refs` input shall be expanded by `bin/expand-otp-refs.sh`
into a flat CSV of concrete refs:

- **`fill`** / **`all`** — one maint-tip per active OTP function
  release line + `maint` + `master` + every master merge commit in
  the rolling 3-month window (`master_history`).
- **`master_history`** — only the 3-month window of master merges,
  no maint-tips.
- **shorthand** (`21`, `22.3`) — expanded against
  `otp_versions.table` to the matching tip.
- **literal refs** (`OTP-28.5`, `master:<sha>`) — passed through.

The 3-month window shall be bounded purely by date
(`AWFY_MERGES_SINCE_DATE`, default `"3 months ago"`), with no
release-tag floor — so the timeline tracks the same horizon
regardless of when the most recent OTP release tagged.

## Resolver

`mix awfy.resolve` (implementation: `Awfy.Fill.Resolve`) shall
turn the expanded ref list into per-(mode, platform) target arrays
the bench workflow's matrices consume directly.

For each ref the resolver shall:

1. Resolve to a 40-char commit SHA. Annotated tags must dereference
   to the commit, not the tag object.
2. Compute the OTP major (`OTP-X.Y...` → X, `master`/`maint` →
   `next-master-major.sh`, bare SHA → `OTP_VERSION` from raw GitHub).
3. In fill mode, probe gh-pages once for existing run-dirs +
   `.benchee` blobs + `NO_INSTALLER` markers, then per-platform:
   - If the platform is in `SKIP_PLATFORMS`, mark "no work".
   - If a `<sha10>-test-<plat>-…/NO_INSTALLER` marker exists, mark
     "no work".
   - If a canonical benchmark set is configured (from
     `mix awfy.measure --dry-run`), the missing-only subset is
     emitted as `target.benchmarks`; otherwise fall back to the
     legacy "any rundir present = done" check.
4. Drop refs where no platform needs work.
5. Cap `master:<sha>` entries kept per run at `MAX_MASTER_MERGES`
   (default 50), oldest-first, *after* the per-platform skip check
   so already-complete merges don't burn cap slots.
6. Emit seven `targets_<mode>_<platform>` JSON arrays + matching
   `has_*` booleans for the workflow's matrix gates.

The resolver shall fail loudly (exit non-zero, no partial output)
if any ref cannot be resolved to a SHA.

## Convergence

Every (SHA, platform) pair must end in one of:

1. **Measured** — `.benchee` files for the canonical set live on
   gh-pages under `<ts>_…_<sha10>-test-<plat>-<arch>-<flavor>/`.
2. **Unmeasurable** — a `NO_INSTALLER` marker sits at
   `<ts>_…_<sha10>-test-<plat>-<arch>-<flavor>-noinstaller/`
   recording why we couldn't measure it (e.g. upstream OTP didn't
   recut the Windows installer for this commit).

A pair that's neither must not stay flagged across consecutive
fills. If the resolver keeps re-queueing the same pair, the
50-merge cap silently burns slots on phantom work — that's a
regression against this invariant.

## Run-dir naming

Run directories on gh-pages and locally shall be named:

    <YYYYMMDDTHHMM>_otp<release>_elixir<version>_<sha10>-test-<plat>-<arch>-<flavor>

with the `-test-` infix coming from the resolver's
`label = "<sha10>-test"`. Variants:

- `…-noinstaller` suffix — the sentinel run-dir written by
  `measure-windows` when upstream had no `otp_win32_installer`
  artifact. Contains a `NO_INSTALLER` file, no `.benchee` blobs.
- `<sha>-dirty_<ts>-…` — locally-dirty trees (uncommitted edits).
  Tolerated locally but not fill candidates.

`Awfy.Fill.Diff.parse_run_dir/1` is the single source of truth for
what shape is recognised by the local fill task.

## Per-target benchmark filter

When a canonical set is configured, the resolver shall emit only
the *missing* benchmark names in `target.benchmarks`, not the
full canonical list. The measure step shall pass that subset to
`mix awfy.measure --benchmarks <list>` so a partial gap doesn't
re-measure the whole suite.

When the missing list is empty for a (sha, platform) but a sibling
platform still needs work for the same SHA, the linux entry shall
carry `skip_synthetic = true` so the measure-linux step gates off
its synthetic-measure step while leaving measure-xmpp-linux running.

## meta.json

Every run-dir shall ship a `meta.json` recording at minimum:

- `git.sha` — the OTP commit measured (not the AWFY repo's SHA).
- `git.timestamp` — commit timestamp, used for the master
  timeline's x-axis.
- `otp_release`, `elixir_version`, `emu_flavor`.
- `hostname`, `machine_class`, `arch`, `os`, `cpu`.
- `build_flags`, `c_compiler_used` — captured from
  `awfy_build_config.txt` + `awfy_compiler.txt` in the OTP prefix.
- For application-bench suites: a `applications` declaration
  listing the family names + metrics this run-dir contributes to
  the geomean (so the dashboard's aggregator can weight them).

A run-dir without a complete `meta.json` is unusable and shall not
reach gh-pages.

## Local fills

`mix awfy.fill` (synthetic / OtpBenchmarks) and
`bin/measure-all-macos.sh` (macOS-specific orchestration) are the
operator-side equivalents of the CI fill path. They shall:

- Use the same run-dir naming as CI (so the resolver's gap check
  sees them).
- Honour the same skip / sentinel conventions.
- Default to running both `jit` + `emu` flavors where applicable,
  with `--flavors` to subset.
- Commit results to a local gh-pages worktree but *never push* —
  the operator pushes after review.

## Canonical benchmark set

The canonical set per suite is the output of
`mix awfy.measure --dry-run` (synthetic + OtpBenchmarks) and
`mix awfy.measure_xmpp --dry-run`. These dry-runs shall print one
benchmark identifier per line on stdout, nothing else (banners
filtered at the bash level in the canonical step), so the
workflow's `grep -E '^[A-Za-z][A-Za-z0-9_]*$' | tr '\n' ','`
pipeline cleanly reduces to the canonical CSV.

Drifting the canonical set (adding/removing benchmarks) does not
retroactively invalidate historical run-dirs — those keep their
existing data — but a SHA whose data predates a new benchmark
will re-queue for that benchmark on the next fill.

## What the pipeline must not do

- Must not silently publish a run-dir that's missing benchmark
  outputs the canonical set expects.
- Must not race two writers against the same gh-pages branch
  (concurrency groups in the workflow enforce this for cron +
  dispatch).
- Must not wipe historical data outside of an explicit
  `otp_refs=all` dispatch.
