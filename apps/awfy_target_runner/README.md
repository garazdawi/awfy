<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# `awfy_target_runner` — target-side Elixir bundle

The minimum amount of Elixir + Benchee required to run AWFY
benchmarks on a pre-OTP-24 target VM. Compiled into a tarball by
[`bin/build-target-bundle.sh`](../../bin/build-target-bundle.sh)
and shelled out to by `Awfy.Runner` on the host (Phase 2 of
[`PLAN/TARGET_ELIXIR_RUNNER_PLAN.md`](../../PLAN/TARGET_ELIXIR_RUNNER_PLAN.md)).

## Why this is a sibling app, not a path-dep

The root project is deliberately not a Mix umbrella — see
`mix.exs:19-25`. `apps/<name>/` houses standalone, individually
compilable apps; this sub-app follows the same convention but is
**not** path-depended-on by the root. Concrete consequences:

- The root `mix compile` does not descend here. Vendored
  target-pinned deps with stripped dev/test trees never enter the
  host `_build`.
- The duplicate `Awfy.TargetRunner` module name (host
  `lib/awfy/target_runner.ex` until Phase 3 deletes it; this
  sub-app from Phase 1 onward) does not collide — they compile
  into separate `_build` trees and are loaded by different VMs
  (host vs target-erl-via-`System.cmd`).

The root `mix precommit` invokes the sub-app's tests via
`mix cmd --cd apps/awfy_target_runner mix test`. Run locally to
validate the runner module before shipping a bundle.

## OTP × Elixir version matrix

The bundle is rebuilt against each pinned target Elixir:

| OTP major | Pinned Elixir | Notes                                  |
| --------- | ------------- | -------------------------------------- |
| 20        | 1.9.4         | Lowest floor; Appendix A/D applied.    |
| 21        | 1.11.4        |                                        |
| 22        | 1.13.4        |                                        |
| 23        | 1.14.5        | Last Elixir compatible with OTP 23.    |
| 24+       | (n/a)         | Modern peer-runner path; setup-beam.   |

OTP ≥ 24 use the pre-built setup-beam Elixir bundles directly; the
target-runner path doesn't apply. See
`PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` § Architecture for the dispatch.

## Vendoring policy

`deps/{benchee,deep_merge,statistex}/` are flat copies of the
upstream Hex packages with their `mix.exs` `defp deps` bodies
stripped of dev/test/docs entries. Mix 1.9 walks the full
transitive `deps()` of every dep regardless of `MIX_ENV` and
`only:` modifiers — and dev/test entries trigger Hex registry
lookups that fail when target OTP is built `--without-ssl`. See
`PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` Appendix A for the
investigation that established this.

The strip is a one-time edit per upgrade. To bump a vendored
version:

```sh
bin/refresh-target-deps.sh                  # interactive: shows the diff
bin/refresh-target-deps.sh --apply          # apply in place
```

The script re-fetches the pinned versions from Hex (via the host's
modern Mix), copies the source trees in, re-applies the strip
edits, and verifies the result compiles under each pinned target
Elixir. Idempotent on no upstream change.

## Building a bundle locally

For pre-24 measurements on a workstation:

```sh
# 1. Build target OTP from source (existing macOS path).
PREFIX="$(./bin/install-otp-source.sh OTP-20.3)"

# 2. Build the bundle against that OTP, pinned to Elixir 1.9.4.
./bin/build-target-bundle.sh "$PREFIX" 1.9.4

# Output: ./target_bundle_1.9.4.tar.gz
```

The bundle script:
1. Builds Elixir from source against the supplied OTP (via
   `bin/install-elixir-source.sh`; cached at
   `~/.local/elixir-src/<version>/`).
2. Compiles the vendored deps + this sub-app under an isolated
   `MIX_HOME` (Appendix C: stale Hex archives compiled for newer
   OTP can't load on OTP 20).
3. Tars the resulting Elixir runtime + sub-app + vendored beams
   into a single archive, layout per `PLAN/TARGET_ELIXIR_RUNNER_PLAN.md`
   § Architecture.

In CI, `prep-target-bundle` (Phase 2) extracts `/opt/otp` from the
per-OTP-SHA Docker image produced by `build-linux` via
[`bin/extract-otp-from-image.sh`](../../bin/extract-otp-from-image.sh)
and feeds the path to the same `build-target-bundle.sh` — no
duplicate OTP source build.

## Argv contract

`Awfy.TargetRunner.main/0` reads from `:init.get_plain_arguments/0`,
which holds everything the host passed after `-extra` (or `--`):

```
$TARGET/bin/erl -noshell \
  -pa $BUNDLE/lib/*/ebin \
  -s 'Elixir.Awfy.TargetRunner' main \
  -extra <module> <inner_iter> <time_s> <warmup_s> <out_path>
```

See the moduledoc in `lib/awfy/target_runner.ex` for the full
contract.
