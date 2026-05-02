# Licensing Policy — REUSE-compliant attribution

Cross-cuts every benchmark plan in this repo. When porting code from
upstream sources (the AWFY suite, the OTP test suites, anywhere
else), attribution and license terms travel with the code.

This repo follows the [REUSE Specification](https://reuse.software/)
for license declarations and copyright attribution. Compliance can
be verified with `reuse lint` (Python tool, `pip install reuse`).

## Repo-level

- **License**: Apache-2.0 for original code authored in this repo.
- **Location**: `LICENSES/Apache-2.0.txt` (canonical Apache 2.0 text).
  This is the REUSE-preferred location; tooling discovers it
  automatically. Additional license texts go alongside it
  (`LICENSES/MIT.txt` etc.) only if a ported file genuinely cannot be
  relicensed under Apache-2.0.
- **Choice rationale**: Apache-2.0 is permissive enough to cover
  MIT-derived code (upstream AWFY) via sublicensing, and matches
  the OTP-derived code that dominates the future port surface
  (`EXTENDED_BENCH_PLAN.md`, `NETWORK_BENCH_PLAN_TIER1.md`).

## Per-file requirements

Every source file (`.erl`, `.ex`, `.exs`, `.sh`, `.ps1`, `.yml`,
`Dockerfile`, etc.) carries:

1. One or more **`SPDX-FileCopyrightText`** lines naming copyright
   holders (year + name + optional email).
2. One **`SPDX-License-Identifier`** line naming the SPDX license
   expression.

Comment-syntax matches the file (`%%`, `#`, `//`, `<!--`).

### Original code (no upstream)

```erlang
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: Apache-2.0
```

### Ports from `erlang/otp` (Apache-2.0 upstream)

Preserve the Ericsson copyright; add ours for the adaptation:

```erlang
%% SPDX-FileCopyrightText: 1996-2025 Ericsson AB. All Rights Reserved.
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: Apache-2.0
%%
%% Ported from erlang/otp:lib/stdlib/test/ets_SUITE.erl
%% Adapted to drive Benchee scenarios; original logic preserved
%% where possible.
```

### Ports from `smarr/are-we-fast-yet` (MIT upstream)

Sublicensed to Apache-2.0 (MIT permits this); preserve original
copyright. The license expression names only the outbound license
since downstream consumers receive Apache-2.0 only:

```erlang
%% SPDX-FileCopyrightText: 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: Apache-2.0
%%
%% Ported from smarr/are-we-fast-yet:benchmarks/Ruby/bounce.rb
%% Translated to Erlang; structure preserved.
```

### Files that can't carry comments (binaries, etc.)

Use a `.license` sidecar file alongside the binary. REUSE picks it
up automatically. Format:

```
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
```

Currently we have no such files; documented for completeness.

## Generated / vendored artefacts

- `mix.lock` — covered by mix's own conventions; no header needed.
- `priv/static/` (chart.js etc. served from CDN, not vendored) —
  no files in the repo, so nothing to attribute.
- If we ever vendor third-party JS/CSS, add per-file SPDX headers
  or sidecars matching the upstream license.

## Compatibility checks before porting from a new source

If the upstream license isn't already Apache-2.0 or MIT, pause
before porting and confirm:

- Is sublicensing under Apache-2.0 permitted by the upstream
  license? (MIT and BSD-style: yes. MPL-2.0: file-by-file. GPL-*:
  no — incompatible.)
- Are there NOTICE-file requirements that need to land at the repo
  root?

Don't paper over license differences with attribution alone.

## Backfill: existing AWFY ports

The 14 AWFY benchmarks already in `lib/awfy/benchmarks/` and `src/`
have informal `Ported from upstream/...` lines but no SPDX headers.
Backfill task: touch each file to add the SPDX header pair plus
Stefan Marr's copyright attribution. Same for support files
(`Awfy.Random`, `awfy_random.erl`).

## Verification

After any porting work:

```sh
pip install reuse        # one-time
reuse lint               # passes only when every tracked file is REUSE-compliant
```

CI integration (future): add a `reuse lint` step to the workflows
so non-compliant PRs fail before merge.
