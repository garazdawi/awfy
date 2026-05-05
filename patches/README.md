<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# OTP build patches

Patches in `patches/OTP-<major>.<minor>/*.patch` are applied to the
OTP source tree before `./configure`, in lexicographic filename
order, with `patch -p1 -N`. The function-release-line directory
(e.g. `OTP-23.0`, `OTP-23.1`) is selected from the build's OTP ref:

| Ref form                   | Patch directory used                         |
|----------------------------|----------------------------------------------|
| `OTP-X.Y.Z` / `OTP-X.Y.Z.W`| `patches/OTP-X.Y/`                           |
| `maint-X` / `master`       | resolved via the source's `OTP_VERSION` file |
| Bare SHA / branch          | resolved via the source's `OTP_VERSION` file |

Both `bin/install-otp-source.sh` (used for macOS and Linux source
builds) and `Dockerfile.linux` apply the same patch set, so a fix
written once works across both environments.

### Per-(major.minor) directories

The maintenance backport policy means that within a single major,
different function-release lines have different sets of fixes
already merged upstream. For example: `OTP-23.2.7` already has the
arm64 darwin LDFLAGS fix that `OTP-23.0.4` does not. To avoid
running brittle "forward-or-reverse" dry-run heuristics at build
time, each function-release line gets its own directory holding
*only* the patches it actually needs:

* `OTP-23.0/` — arm64/aarch64 chk_arch_, arm64 darwin LDFLAGS,
  in6addr stdio, macOS version check removal, erl_db_util variadic
  BIF (7 fixes)
* `OTP-23.1/` — only the missing aarch64 chk_arch_ entry
* `OTP-23.2/` — only the missing aarch64 chk_arch_ entry
* `OTP-23.3/` — nothing (all upstream)

The build script just iterates `patches/OTP-X.Y/*.patch` and
forward-applies each one. No dry-runs, no reverse logic, no fuzz —
if a patch is in the directory, it must apply cleanly.

Patches shared across function-release lines within the same major
are kept as relative symlinks back to the canonical copy, e.g.
`patches/OTP-23.1/01-add-aarch64-arch.patch` →
`../OTP-23.0/01-add-aarch64-arch.patch`. Git tracks the symlink, so
a single edit to the canonical patch propagates everywhere.

When adding a new fix:

1. **Each `.patch` file should fix exactly one upstream issue** with
   the simplest possible shape — a pure addition or a pure deletion.
   Splitting the fix this way makes it easier to drop just the parts
   that have been backported when a new function-release tip rolls
   forward.
2. **Place the patch only in the directories where it applies.**
   Run `patch -p1 -N --dry-run` against each candidate function-
   release tip to find out which lines need the fix; symlink-share
   across the ones that do.
3. **Patches must apply with `patch -p1 -N`** (no fuzz, no reverse).
   The build aborts if any patch in the directory fails to apply.

## File format

Patches are unified diffs against the OTP source tree, with paths
relative to the OTP root (`-p1` strip). Add a header block above the
diff naming the failure they fix and the OTP commit / version where
the upstream fix landed (if any), so the next person can tell whether
the patch is still needed:

```
# Fixes: build failure on OpenSSL 3 with OTP 22 — `RSA_get_key`
#        and `EVP_MD_size` were removed.
# Upstream: fixed in OTP 23.2 (commit abc1234).
# Drop this once we no longer build any OTP < 23.

--- a/lib/crypto/c_src/openssl_config.h
+++ b/lib/crypto/c_src/openssl_config.h
@@ -1,5 +1,7 @@
 #include <openssl/opensslv.h>
+...
```

## Notes per OTP major

Each pre-JIT release has its own quirks beyond just patching. Notable:

* **OTP 20**: HiPE *is* the "JIT" for this version — the BEAM JIT
  doesn't land until OTP 24. When the workflow asks for the `jit`
  flavor on OTP 20 we should compile the benchmark sources with
  `erlc +native …` (or call `hipe:c/1` at runtime) so HiPE actually
  takes effect; without that, "jit" silently runs the same code as
  "emu". The `emu_flavor` runtime flag also doesn't exist yet on
  OTP 20-23 — use plain `erl` for emu and HiPE-compiled beams for jit.
  See the runner's flavor-mapping logic for the per-major translation.

* **OTP 21-23**: HiPE still available; native flag works the same way.
  `+native` is still the path to "JIT-equivalent" for these versions.

* **OTP 24-27**: BEAM JIT replaced HiPE and is on by default. Flavor
  is selected with `-emu_flavor jit|emu` at runtime (jit is default).
  HiPE is gone (removed in OTP 24).

* **OTP 28+**: same as 24-27; the names `jit`/`emu` are the upstream
  spelling.

## Common patch categories

The Erlang/OTP source tree changed enough between OTP 20 and OTP 28
that several mechanical fixes are needed to build older releases on
modern toolchains. Patches likely to live here over time:

* **OpenSSL compatibility** — OpenSSL 3 removed deprecated APIs
  (`RSA_get_key`, `EVP_MD_size`, low-level RSA accessors) that crypto
  NIFs in OTP < 23 still use. The Linux Docker image side-steps this
  by basing on `debian:bullseye-slim` (OpenSSL 1.1.1 native), but the
  macOS source-build path still needs the patch when Homebrew's
  default `openssl@3` is in scope.
* **Compiler warnings as errors** — newer GCC and clang promote
  warnings like `-Wimplicit-function-declaration` to errors by
  default. OTP < 23 has a few stale prototypes that need fixing
  (or the warning suppressed).
* **macOS SDK / Apple Silicon** — `clock_gettime`, `mach_*`, and
  build system assumptions changed; OTP < 24 generally needs help to
  build natively on `arm64-apple-darwin`.
* **autoconf 2.71+** — `AC_PROG_CC_C99` was removed; some configure
  scripts in OTP < 22 hit "undefined macro" failures with newer
  autoconf.

## How to add a patch

1. Reproduce the build failure on a clean checkout of the target OTP
   ref. (Easiest: `git clone --depth 1 -b OTP-X.Y.Z
   https://github.com/erlang/otp.git /tmp/otp` then run the same
   `./configure …` and `make` the workflow does.)
2. Make the smallest fix that compiles. Test that `erl` boots and
   `mix awfy.measure --benchmarks Bounce --time 1 --warmup 0` runs.
3. `cd /tmp/otp && git diff > /Users/lukas/code/awfy/patches/OTP-X.Y/01-short-name.patch`.
   Use a numeric prefix to control apply order if patches depend on
   each other. Keep each `.patch` to a single upstream issue (see
   "Per-(major.minor) directories" above) — split a multi-hunk fix
   into one file per hunk if the hunks could be backported separately.
   If the same fix applies to multiple function-release lines in the
   same major, symlink-share it from a canonical directory.
4. Add the header comment described above.
5. Commit. The next workflow run will pick the patch up automatically.

If the failure is in the build chain rather than the source (missing
package, wrong autoconf, etc.), fix it in `Dockerfile.linux` /
`bin/install-otp-source.sh` rather than carrying a patch.
