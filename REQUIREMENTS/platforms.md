# Platforms — Requirements

This file specifies the (OS, architecture, OTP-major) matrix AWFY
supports, and the per-cell behaviour each combination requires.

See also: [Measurement](measurement.md), [Infrastructure](infrastructure.md).

## Support matrix

| Platform          | Arch    | Modern (OTP ≥ 24) | Legacy (OTP < 24) | Where measured           |
| ----------------- | ------- | ----------------- | ----------------- | ------------------------ |
| `linux-x86_64`    | x86_64  | yes               | yes               | GHA / AWS c6i.4xlarge    |
| `linux-arm64`     | arm64   | yes               | yes               | GHA / AWS c7g.4xlarge    |
| `macos-arm64`     | arm64   | yes               | yes               | Local M5 (CI gated off)  |
| `windows-x86_64`  | x86_64  | yes               | yes               | GHA / AWS c6i.4xlarge    |

OTP majors covered: **20 through master** (currently 30). Per-major
support is per the JIT cutoffs below.

## Modern vs legacy split

The pipeline shall split at **OTP-24** based on what the runtime
contract supports:

- **Modern path (OTP ≥ 24).** Same-OTP measurement: the BencheeRunner
  runs `mix awfy.measure` under the target OTP directly (peer
  runner). Bench scripts compile against the same Elixir that
  ships in the bundle.
- **Legacy path (OTP < 24).** Cross-Elixir target-bundle. The
  benchmark source is compiled by the older Elixir paired with the
  target OTP (`apps/awfy_target_runner/`), then the host
  orchestrator dispatches measurements to that target via
  `AWFY_TARGET_ERL` / `AWFY_TARGET_BUNDLE`.

The dashboard shall surface which path produced each cell so a
reader can interpret cross-path comparisons. A modern-path and a
legacy-path measurement of the same SHA at the same
(platform, flavor) are presented as equivalent only if explicitly
labelled.

## JIT cutoff

The BeamAsm JIT lands at different OTP versions per architecture:

| Platform          | First JIT version |
| ----------------- | ----------------- |
| `linux-x86_64`    | OTP-24            |
| `linux-arm64`     | OTP-25            |
| `macos-arm64`     | OTP-26            |
| `windows-x86_64`  | OTP-24            |

The dashboard shall apply this cutoff at render time:

- Pre-cutoff data is shown only in `emu` flavor.
- Post-cutoff data is shown only in `jit` flavor.

Measurements collect both flavors where possible (so a future
cutoff change doesn't require re-measuring history) — the cutoff
is purely a display rule.

## XMPP applicability

The XMPP suite (MongooseIM + Amoc) shall only apply to:

- Linux platforms (x86_64 and arm64).
- OTP-27 and newer (MongooseIM dropped OTP-26 in 6.6.5; the pinned
  6.6.0 tree doesn't build on 26 either).

`master` and `master:<sha>` count as OTP-27+ in the current era.
Outside this scope, XMPP is silently skipped (no SHA flagged as
"needs xmpp" for unsupported platforms / majors).

## Source acquisition

Each platform's measure job fetches OTP source for the target SHA
via the following priority (`bin/fetch-otp-source.sh`):

1. **Release tarball** (`github.com/erlang/otp/releases/.../otp_src_*.tar.gz`)
   — covers `OTP-*` tagged refs.
2. **erlang.org tarball** — covers older majors + main releases
   that pre-date GitHub releases.
3. **otp_prebuilt artifact** — covers branch / SHA refs (`master`,
   `maint-*`). Requires upstream's `Build and check` CI to have
   completed for that commit; expires after ~90 days per GitHub
   artifact retention.
4. **GitHub archive fallback** (`/archive/<sha>.tar.gz`) — modern
   refs only (`master`, `maint`, `master:*`, OTP-≥24 OTP-* tags,
   and bare 40-hex SHAs). Last resort when (3) has aged out.

Path (4) is gated to modern OTP because pre-24 branches don't
commit `configure` to git and the patches in `patches/OTP-X.Y/*.patch`
are line-numbered against the canonical release tarball — a
regenerated configure would silently drift.

If all paths miss, the job fails loudly. Never silently produce a
degraded build.

## SKIP_PLATFORMS

A platform that's intentionally not measurable in CI on this run
shall be passed via `SKIP_PLATFORMS` (CSV env var) to the resolver.
The resolver treats listed platforms as out-of-scope:

- Their gap check returns "no missing" so a SHA whose only gap is
  on a skipped platform is not flagged.
- No matrix entry is emitted for the platform.

`bench.yml` currently sets `SKIP_PLATFORMS=macos` because
`measure-macos` is `if: false` while the M5 local sweep is the
authoritative source. Removing the `if: false` and dropping the
env var are co-located changes.

## NO_INSTALLER sentinel

When `bin/install-otp-windows.ps1` soft-skips (no upstream
`otp_win32_installer` artifact — typical for master commits with
no C code changes), `measure-windows` shall write a sentinel
run-dir to `results/`:

    <ts>_otp<rel>_elixir<v>_<sha10>-test-windows-x86_64-<flavor>-noinstaller/
        NO_INSTALLER

The publish step copies this to gh-pages like any other run-dir.
The resolver's gh-pages tree probe recognises the `NO_INSTALLER`
filename and treats the (sha, windows) slot as "complete
(unmeasurable)" so the SHA stops re-queueing every fill.

Same sentinel pattern shall be used for any future platform-level
unmeasurable case. The pattern is a *durable* statement that this
slot can never produce data, not a temporary "try again later"
marker.

## Local M5 sweep

macOS measurements are produced by `bin/measure-all-macos.sh` on
the operator's M5 hardware. The sweep shall:

- Iterate `bin/expand-otp-refs.sh all` by default (every maint-tip
  + the 3-month master_history window).
- Skip refs whose OTP install is already cached at
  `~/.local/otp/<sha>`.
- Skip (sha, flavor) pairs whose run-dir already exists locally.
- Support a `--build-only` mode that pre-warms OTP source builds
  without measuring (so a measurement sweep then runs on warm
  caches).
- Default flavors: `jit,emu`. The dashboard's JIT cutoff hides
  the irrelevant flavor per (platform, OTP) cell.

## Per-platform OTP install method

| Platform          | Install method                                              |
| ----------------- | ----------------------------------------------------------- |
| `linux-x86_64`    | Build from source inside Dockerfile.linux (per-SHA image).  |
| `linux-arm64`     | Same, arm64 image variant.                                  |
| `macos-arm64`     | Source build via `bin/install-otp-source-mac.sh`.           |
| `windows-x86_64`  | Download upstream `otp_win32_installer` artifact.           |

Windows is the only platform that doesn't source-build. Its
dependency on upstream artifacts is the reason for the
`NO_INSTALLER` sentinel mechanism.
