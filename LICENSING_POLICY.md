<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# Licensing Policy — REUSE-compliant attribution

Cross-cuts every benchmark plan in this repo. When porting code from
upstream sources (the AWFY suite, the OTP test suites, anywhere
else), attribution and license terms travel with the code.

This repo follows the [REUSE Specification](https://reuse.software/)
for license declarations and copyright attribution. Compliance can
be verified with `reuse lint` (Python tool, `pip install reuse`).

## Repo-level

- **License (original code)**: Apache-2.0.
- **Per-file licenses for ports**: match upstream. AWFY ports stay
  under MIT, OTP ports stay under Apache-2.0. REUSE supports
  per-file licensing — this is exactly the pattern it's designed for.
- **License-text locations** (REUSE-preferred):
  - `LICENSES/Apache-2.0.txt` — covers original code + OTP ports.
  - `LICENSES/MIT.txt` — covers AWFY ports.
- **Why not relicense AWFY ports to Apache-2.0?** MIT permits
  sublicensing in principle, but its permission notice still has
  to ride along with the file regardless of what we sublicense
  to. So calling the SPDX identifier `Apache-2.0` while the MIT
  notice is required to travel with the code is just a confusing
  way to spell `MIT`. Cleaner to call it MIT and skip the
  sublicensing argument.

## Per-file requirements

**Rule: every file carries its own SPDX header inline.** If a file
moves out of the repo — copied into another project, pasted into a
gist, attached to a bug report — the copyright and licence travel
with it. Bulk annotations in `REUSE.toml` are reserved for files
that *cannot* carry inline comments (binary blobs, JSON, generated
files that get rewritten by tooling). Markdown, shell, dotfiles,
patches, etc. — all use inline headers.

Required:

1. One or more **`SPDX-FileCopyrightText`** lines naming copyright
   holders (year + name + optional email).
2. One **`SPDX-License-Identifier`** line naming the SPDX license
   expression.

Comment-syntax matches the file (`%%`, `#`, `//`, `<!--`). For
patch files the headers go above the unified-diff body, in the
prose comment block — `patch -p1` ignores everything before the
first `--- ` line, so SPDX lines there are safe.

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

Stays under MIT — same license as upstream. The bulk of the IP is
Stefan Marr's algorithms and structure; we translated to Erlang/Elixir
but the original work dominates. Keeping the file under MIT preserves
clear lineage and avoids the sublicensing ambiguity of "we relicensed
to Apache-2.0 but still have to drag the MIT notice along anyway."

```erlang
%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT
%%
%% Ported from smarr/are-we-fast-yet:benchmarks/Ruby/bounce.rb
%% Translated to Erlang; structure preserved.
```

Repo-level LICENSE remains Apache-2.0 for original framework code;
AWFY ports are MIT per-file. REUSE supports per-file licensing —
this is exactly the pattern it's designed for.

### Files that can't carry comments (binaries, JSON, generated)

Add an `[[annotations]]` block to `REUSE.toml` instead. The toml
file is the one place to look when asking "where's the licence
for this binary?", which is more discoverable than a `.license`
sidecar scattered next to each file.

In this repo, the `REUSE.toml` list is intentionally short —
`mix.lock` (Elixir mix rewrites the file wholesale, so a leading
comment wouldn't survive `mix deps.get`) and
`apps/awfy/priv/rap_benchmark.json` (JSON has no comment syntax).
Adding a new entry there should answer "what comment syntax does
this file have?" with "none" before it lands.

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
