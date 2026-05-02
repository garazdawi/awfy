# Licensing Policy — preserved attribution for ported benchmarks

Cross-cuts every benchmark plan in this repo. When porting code from
upstream sources (the AWFY suite, the OTP test suites, anywhere
else), attribution and license terms travel with the code.

## Repo-level

- Top-level `LICENSE` is **Apache-2.0**.
- Choice rationale: OTP-derived code (the bulk of `EXTENDED_BENCH_PLAN.md`
  and `NETWORK_BENCH_PLAN_TIER1.md`) is Apache-2.0; AWFY-derived code is
  MIT (which Apache-2.0 covers); our own original code is fine under
  Apache-2.0.

## Per-file requirements

Every source file (`.erl`, `.ex`, `.exs`, `.sh`, `.ps1`, etc.) gets:

1. An SPDX header on the first or second line:
   ```
   %% SPDX-License-Identifier: Apache-2.0
   ```
   (Erlang form; use `# SPDX-License-Identifier: Apache-2.0` for shell
   / PowerShell, `// SPDX-License-Identifier: Apache-2.0` for any C
   we end up with, etc.)

2. **For ported files**: a copyright + provenance line directly after
   the SPDX header that names the original project, the file path
   inside that project, and (where applicable) the upstream copyright
   holders. Example for an OTP-derived file:

   ```
   %% SPDX-License-Identifier: Apache-2.0
   %%
   %% Ported from erlang/otp:lib/stdlib/test/ets_SUITE.erl
   %%   Copyright Ericsson AB 1996-2025. All Rights Reserved.
   %%
   %% Adapted to drive Benchee scenarios; original logic preserved
   %% where possible.
   ```

   Example for an AWFY-derived file:

   ```
   %% SPDX-License-Identifier: MIT
   %%
   %% Ported from smarr/are-we-fast-yet:benchmarks/Ruby/bounce.rb
   %%   Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
   %%
   %% Translated to Erlang; structure preserved.
   ```

3. **For original files** (no upstream): only the SPDX header.
   The repo's top-level `LICENSE` covers them by default.

## Per-license guidance

| Source | License | What ships in the ported file |
|--------|---------|-------------------------------|
| `erlang/otp` | Apache-2.0 | Preserve the Ericsson copyright header verbatim; add SPDX |
| `smarr/are-we-fast-yet` | MIT | Preserve Stefan Marr's copyright; SPDX line names MIT |
| Original work | (Apache-2.0 by repo) | SPDX header only |

If we ever pull from a project under a *different* license (BSD-3,
MPL-2.0, etc.), pause and verify compatibility with Apache-2.0
before porting. Don't paper over license differences with attribution
alone — some licenses require additional notices in the LICENSE file
or a separate `NOTICES` document.

## What this means for the existing AWFY ports

The 14 AWFY benchmarks already in `lib/awfy/benchmarks/` and `src/`
have `Ported from upstream/...` lines but no SPDX headers and no
explicit copyright attribution. Adding those is a one-time cleanup
pass — touch every existing port to add `SPDX-License-Identifier:
MIT` plus the upstream copyright line. Same for the support files
(`Awfy.Random`, `awfy_random.erl` — both ported from AWFY).

## What this means for new ports

Every benchmark added by `EXTENDED_BENCH_PLAN.md` or
`NETWORK_BENCH_PLAN_TIER1.md` must include the SPDX + copyright +
provenance lines from day one. Reviewers should bounce PRs that
omit them.

## Sequence

1. Add `LICENSE` (Apache-2.0) at repo root. (Done in same commit
   as this policy.)
2. One-time backfill: add SPDX + attribution headers to existing
   AWFY ports.
3. New ports follow the per-file template from day one.
