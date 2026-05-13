<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# AWFY Benchmark Infrastructure Refactor Plan

Audit and refactor plan for the AWFY + OtpBenchmarks + XMPP measurement paths, captured after integrating the XMPP application-bench (3-broker CETS cluster) on top of the AWFY synthetic + OtpBenchmarks scaffolding.

The pattern observed: each measurement path was added by **copy-paste-and-tweak** rather than by abstracting out the previous one. The result is five `git_state` clones, three `os_string`/`cpu_string` clones, two `slim_suite` implementations, two `meta.json` writers, and three independent dispatches on `:os.type()`. Several silent-divergence bugs already exist between these copies — flagged below.

## Suggested sequencing

Each item is independently shippable. Ordered to land the highest-bug-prevention work behind a safety net, then progressively reduce duplication.

1. **§7 (smoke assertions) first** — no production code change, catches existing bugs, makes subsequent refactors safe.
2. **§4 (Machine.describe)** and **§3 (RunContext)** — foundational primitives §1 builds on. Order doesn't matter much between them; RunContext has the bigger payoff.
3. **§1 (Meta.write)** — drops out cleanly once §3 + §4 are in place.
4. **§6 (Measure.Setup helpers)** — falls out for free once §1 + §3 land.
5. **§2 (SuiteSlim codegen)** — independent of everything else; can land in parallel.
6. **§5 (Topology + MetricSource behaviours)** — last, future-proofing for Phase 2 network-bench + Phase 4 Prometheus migration.

Total estimated: 1500–1800 lines across the chain. Each step reduces surface for the next.

## Summary table

| Area | Effort | Bug-prevention ROI | Migration risk |
|---|---|---|---|
| 1. meta.json schema | medium | high (silent field drift) | low — additive |
| 2. SuiteSlim dup | small | medium (drift exists today) | low — codegen at build |
| 3. RunContext | medium | **highest** (months-long bugs documented) | medium — touches writer-reader contract |
| 4. Machine.describe | small | medium (`+S` mismatch, future probes) | low — additive |
| 5. Topology behaviours | medium | medium (preempts Phase 4 + network-bench) | low — purely structural |
| 6. Measure.Setup helpers | small | low (cosmetic) | low |
| 7. Smoke assertions | medium | high (catches all of 1, 3, 5) | none |

---

## 1. meta.json schema fragmentation

### Problem

Three writers produce `meta.json` with overlapping-but-not-identical fields; there is no shared schema or builder.

- `lib/mix/tasks/awfy.measure.ex:314–356` (`write_meta/2`): the canonical AWFY synthetic / OtpBenchmarks writer. Emits `format_version`, `label`, `otp`, `elixir`, `timestamp`, `git{sha,dirty}`, `machine{hostname,os,cpu,arch,cores}`, `runtime{emu_flavor,schedulers_online,logical_processors,wordsize,smp_support,nif_version,driver_version,c_compiler_used,mix_env}`, `config{time,warmup,lang,build_flags}`, `benchmarks[]`, `otp_benchmarks[]`.
- `lib/mix/tasks/awfy.measure_xmpp.ex:169–222` (`write_meta/2`): the XMPP writer. Same `format_version`/`label`/`otp`/`elixir`/`timestamp`/`git`/`machine` blocks, but **omits** the entire `runtime` block, **omits** `config`, **omits** `benchmarks`/`otp_benchmarks`, and **adds** an `xmpp{scenario,topology,users,domains,interarrival_ms,measurement_duration_s,throughput,cpu_pct,mem_mb}` block plus `applications:[{name,metrics}]`.
- `apps/awfy_target_runner/lib/awfy/target_runner.ex` does **not** write meta.json — the bundle's role is to produce a `.benchee` file only; the host's `awfy.measure` writes the surrounding meta when the bundle path is used. Correct division of labour but means the AWFY meta writer is in fact the legacy-bundle meta writer too.
- `lib/awfy/measure/helpers.ex` hosts `otp_version_label/0`, `trend_timestamp/0`, `safe_integer/1` — but not the meta writer itself. Both callsites duplicate the same JSON structure literal.

### Specific silent divergences

- **`elixir` field**: `awfy.measure.ex:441–446` reads `AWFY_TARGET_ELIXIR_VERSION` first (correct for legacy bundle runs); `awfy.measure_xmpp.ex:176` calls `System.version()` directly. If XMPP ever runs through a legacy bundle path, the dashboard will mistag those runs with the host's Elixir version.
- **`machine` block**: identical fields but each file has its own `os_string/0` (`measure.ex:528–534` vs `measure_xmpp.ex:237–243`), `cpu_string/0` (`measure.ex:536–552` vs `measure_xmpp.ex:245–262`), `trim_cmd/2` (`measure.ex:554–559` vs `measure_xmpp.ex:264–269`). Both Linux branches call `Awfy.Preflight.Parse.cpuinfo_field/2` so the parser is shared, but a future fix to `os_string` (WSL detection, FreeBSD support) lands in one copy and silently drifts the other.
- **`runtime` block missing from XMPP**: `Awfy.Compare.Data.load_run/1` reads `meta["runtime"] || %{}` (data.ex:93), so the dashboard treats every XMPP row as `runtime: %{}`. Works today only because the row builder falls back to `flavor_from_label(run.label)` (data.ex:181 — see §3); but `schedulers_online` and `logical_processors` are silently `nil` for every XMPP row, so any future "schedulers vs throughput" chart would silently exclude XMPP.
- **`format_version`**: both files declare `@format_version 1` separately (`measure.ex:74`, `measure_xmpp.ex:44`). Bumping the schema requires editing both; nothing enforces they stay equal. `data.ex:90` reads it but doesn't gate behaviour on it.
- **`applications` field semantics**: only emitted by the XMPP writer, but the synthetic writer's absence of the field is what tells `Awfy.Compare.Data.categorize/2` (data.ex:472–474) that every row is `:synthetic`. Architecturally only works because XMPP and synthetic runs live in separate run-dirs.
- **`git` block**: `git_state/0` cloned in both files (`measure.ex:273–277` vs `measure_xmpp.ex:224–228`) — identical bodies.
- **`timestamp` source**: both correctly route through `Helpers.trend_timestamp/0`. (Lucky — the helper already existed.)

### Proposed refactor

Introduce `Awfy.Measure.Meta` (`lib/awfy/measure/meta.ex`) with two responsibilities:

1. **`base/1`** — builds the *derived* portion of the meta map (everything not scenario-specific): `format_version`, `label`, `otp`, `elixir`, `timestamp`, `git`, `machine`, `runtime`, plus the `config` block when a `config` keyword is passed. Identical for AWFY, OtpBenchmarks, and XMPP runs — only the source of these fields varies via env vars already resolved by `Helpers`.
2. **`write/2`** — `(dir, scenario_specific_map)` deep-merges scenario-specific fields (`benchmarks`, `otp_benchmarks`, `xmpp`, `applications`, future `network`) on top of `base/1` and writes the file.

Migration order:

1. Move `os_string/0`, `cpu_string/0`, `trim_cmd/2`, `git_state/0` to `Awfy.Measure.Meta` (or `Awfy.Measure.Machine` per §4) as public functions.
2. Build `Meta.base/1` and `Meta.write/2`. Add a `Meta.format_version/0` accessor.
3. Replace `awfy.measure.ex:314–356` and `awfy.measure_xmpp.ex:169–222` with `Meta.write(dir, scenario_block)`. Both writers shrink to ~10 lines.
4. Add a single `Awfy.Measure.MetaSchema` validator (NimbleOptions or plain `validate/1`) used by both unit tests (after `Meta.write`) and the smoke job (§7).
5. After both writers are unified, raise `format_version` to 2 to capture the now-present `runtime` + `config` blocks in XMPP meta. Migrate dashboard accordingly (data.ex already handles missing fields, so no-op uplift).

**Effort: medium (~250 lines including new module, deleted duplicates, and unit tests).**

---

## 2. SuiteSlim duplication in target_runner

### Problem

`lib/awfy/suite_slim.ex:47–75` and `apps/awfy_target_runner/lib/awfy/target_runner.ex:352–385` have byte-identical `slim_*` private functions. The duplication is intentional per the moduledoc on `suite_slim.ex:37–39` and `target_runner.ex:347–351` — the cross-OTP bundle ships without the runner project's code path, so it has to vendor anything it needs.

### Scope of duplication

- `write_slim_suite/2` (target_runner.ex:352–363) ↔ `SuiteSlim.slim/1` (suite_slim.ex:47–53).
- `slim_scenario/1` (target_runner.ex:365–373) ↔ `SuiteSlim.slim_scenario/1` (suite_slim.ex:55–63).
- `clear_samples/1`, `clear_outliers/1`, `clear_configuration_inputs/1` — all three private functions byte-identical across the two files.

The `awfy.measure_xmpp.ex:132–138` slim_suite cleverly delegates to `SuiteSlim.slim/1` when Benchee is loaded — that callsite is OK.

### Bug surface

The same duplication pattern exists for `adjust_for_batching/2` (target_runner.ex:297–343 ↔ `lib/awfy/otp_benchmarks/runner.ex:234–279`) — but that one is NOT documented as intentional. Both do exactly the same divide-by-batch on percentiles + sample-size-times-batch. If one ever drifts (someone adding a new field to `Benchee.Statistics` that needs adjustment), the bundle-target leg will silently emit different numbers than the peer-flow leg for the same OTP version.

### Proposed refactor: codegen at bundle build time

Three options, ranked by how invasive they are:

**(A) Codegen at bundle build time (recommended).** Have `bin/build-target-bundle.sh` (which already vendors Benchee) copy `lib/awfy/suite_slim.ex` into `apps/awfy_target_runner/lib/awfy/suite_slim.ex` as a build step, then have `target_runner.ex` `alias` it. Bundle build is the only place that needs to know about the synced file; the runner project's tree stays clean (could even `.gitignore` the synced copy so accidental hand-edits get reverted next build). Eliminates duplication without making `awfy_target_runner` a path-dep — the explicit non-goal in `PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` decision #10.

**(B) Vendor via a make-style "make slim" step.** Same idea, hand-rolled — `mix awfy.target_bundle.sync` copies the file before packaging. Slightly less automatic than (A) but doesn't require modifying any shell script.

**(C) Make `awfy_target_runner` actually depend on a tiny third app `awfy_suite_slim`.** This is the option the PLAN decision argues against — multiplies apps inside the runner project, forces the bundle to ship one more `_build`-style dir. Don't do this.

For both `slim_*` *and* `adjust_for_batching`, the same codegen approach scales — add `lib/awfy/measure/batch_adjust.ex`, sync into the bundle at build time.

**Effort: small (~100 lines).** One shell-script tweak in `bin/build-target-bundle.sh`, one new alias in `target_runner.ex`, deletion of ~30 lines duplicated private functions, plus the equivalent for `adjust_for_batching` (~50 lines).

---

## 3. OTP version + emu flavor metadata — multiple sources of truth

### Problem

The OTP version and emu flavor stored in `meta.json` are computed from up to **six** different sources, with one explicit override (`flavor_from_label`) in the dashboard layer that *negates* the runtime info because the latter is known-wrong on the legacy bundle path. The complexity is load-bearing for cross-OTP runs but the resolution logic is now scattered across writer, helper, env, label, file, and reader.

### Readers/writers map

**Where the OTP version label comes from** (in priority order):

- `AWFY_OTP_VERSION` env var — set by CI per matrix row (`bench.yml:623, 793, 921, 1020, 1140, 1230, 1353`).
- `<otp_root>/releases/<release>/OTP_VERSION` file — read by `Helpers.otp_version_label_from_file/0` (helpers.ex:121–135).
- `System.otp_release/0` — last-resort fallback (helpers.ex:111).
- All three funnel into `Helpers.otp_version_label/0` (helpers.ex:104–113) which writes the resolved value into `meta["otp"]` at both `measure.ex:320` and `measure_xmpp.ex:175`.
- **Readers**: `Awfy.Compare.Data.load_run/1` (data.ex:88) reads `meta["otp"]`; `Awfy.Compare.Data.rows_for_run/1` propagates `run.otp` into every row (data.ex:170). The dashboard uses it as the trend x-axis.

**Where the run-dir name's OTP comes from** (separate from `meta["otp"]`):

- `Helpers.run_dir/5` (helpers.ex:43–46) embeds `otp<otp_release>` into the dir name.
- Callers pass **`System.otp_release()`** at `measure.ex:96` and `measure_xmpp.ex:67` — *NOT* `Helpers.otp_version_label()`. So the dir says `otp27` but `meta["otp"]` says `27.3.4`. Deliberate (the dir is parseable by `Awfy.Fill.Diff.parse_run_dir`, fill.diff.ex:39) but means the run-dir name and meta.json field disagree on what "OTP version" means.

**Where the timestamp comes from**:

- `AWFY_OTP_COMMIT_TIMESTAMP` env var — set by CI per matrix row.
- Wall clock — fallback (helpers.ex:151–156).
- Funnels into `Helpers.trend_timestamp/0` (helpers.ex:148–167). The malformed-value warn-and-fall-back behaviour was added because "silent fallback hid a months-old config bug in a previous iteration" (helpers.ex:144–147) — this exact area has already caused a months-long invisible bug.

**Where the emu flavor comes from** (three sources, partial overlap):

- `:erlang.system_info(:emu_flavor)` — written into `meta["runtime"]["emu_flavor"]` at measure.ex:335.
- The label suffix `-jit` / `-emu` — appended by the caller (`bench.yml`-driven label for fill runs, or `bin/measure-all-macos.sh`).
- `ERL_FLAGS=-emu_flavor emu` — set by CI per matrix row (`bench.yml:621, 791, 919`) and by `fill.ex:248` (`build_env/3`).
- Read by `Awfy.Compare.Data.rows_for_run/1` at data.ex:181: `emu_flavor: flavor_from_label(run.label) || get(run.runtime, "emu_flavor")` — i.e. **the label trumps the runtime info**, explicitly because on the legacy bundle path the runtime emu_flavor is the *host's*, not the target's. See data.ex:173–180 for the bug history.
- The XMPP path doesn't write `runtime.emu_flavor` at all (§1), so for XMPP rows it's *always* `flavor_from_label`.

### Silent-disagreement modes already-burned

1. **Bundle-mode mistag** (data.ex:173–180, fixed): host runs JIT, target runs emu, `meta["runtime"]["emu_flavor"] == "jit"` for every emu-tagged legacy run. Workaround: read from the label instead. Workaround is correct but `meta.json` is now misleading on disk.
2. **XMPP emu reporting** (currently OK by accident): XMPP runs go through `mix awfy.measure_xmpp` on the host where `emu_flavor: "jit"` (or whatever the host has), but the MongooseIM container is the one that gets `MIM_ERL_FLAGS=-emu_flavor emu`. The host's `runtime.emu_flavor` is wrong for the same reason as bundle mode. The `flavor_from_label` workaround happens to also save XMPP because the CI label embeds the flavor suffix (`bench.yml:1364–1365`). Local `mix awfy.measure_xmpp` invocations without explicit `--label` would be affected — `auto_label` produces a SHA-only label, no flavor suffix.
3. **Timestamp drift on retroactive runs** (helpers.ex:144–147): documented as already-burned.
4. **Run-dir vs meta OTP** — `otp27` in the dir name vs `27.3.4` in meta is fine for `Awfy.Fill.Diff` (which only parses major), but the next bug will likely be someone reading the dir name expecting the full version.

### Proposed refactor: `Awfy.RunContext`

Introduce `Awfy.RunContext` as a tagged, validated record built once at the start of each measure task:

```elixir
%Awfy.RunContext{
  otp_label:        String.t(),     # AWFY_OTP_VERSION || file || release
  otp_release:      String.t(),     # System.otp_release/0 — run-dir name only
  elixir_version:   String.t(),     # AWFY_TARGET_ELIXIR_VERSION || System.version()
  emu_flavor:       :jit | :emu,    # resolved from label suffix THEN runtime
  schedulers:       integer(),
  trend_timestamp:  DateTime.t(),
  git_sha:          String.t(),
  git_dirty:        boolean(),
  label:            String.t(),
  flavor_source:    :label | :runtime,  # debugging silent overrides
  scenario:         :synthetic | :otp_benchmarks | :xmpp | :network
}
```

- Single builder: `RunContext.new(opts, env: env, runtime: runtime)` — pure function, fully unit-testable, would have caught the months-old config bug helpers.ex:144 documents.
- All three writers (`awfy.measure`, `awfy.measure_xmpp`, future `awfy.measure_network`) build a `RunContext` once and hand it to `Meta.write/2`. No writer reads env vars directly anymore.
- `Awfy.Compare.Data` reads `meta["otp"]`/`meta["emu_flavor"]` but ALSO accepts a `RunContext` shape directly. Remove `flavor_from_label/1` from data.ex (data.ex:349–357) — emu_flavor resolution moves to write-time, where the writer knows whether it's a host-or-target situation. If the bundle path needs to override the host's `:erlang.system_info(:emu_flavor)`, do it explicitly via `--flavor emu` on the CLI (already implicit in the label), then write the resolved value to `meta["runtime"]["emu_flavor"]` and stop trying to recover it from the label downstream.

Migration order:

1. Build `Awfy.RunContext.new/1` + tests.
2. Switch `awfy.measure.ex` to consume it. `flavor_from_label` becomes a build-time helper invoked only when constructing the RunContext.
3. Switch `awfy.measure_xmpp.ex` to consume it (immediately fixes XMPP's missing `runtime` block + mis-attributed `emu_flavor`).
4. Drop `flavor_from_label/1` from `data.ex` and remove the override at data.ex:181 once both writers are honest about which flavor actually ran.

**Effort: medium (~300 lines + heavy test coverage; highest bug-prevention ROI in the audit).**

---

## 4. Machine / OS detection scattered across 5+ files

### Problem

There is no single `Machine.describe/0` returning the meta.json `machine` block. The probes are reimplemented in each module that needs them.

### Inventory

| File | Lines | What it probes | Tool |
|---|---|---|---|
| `lib/mix/tasks/awfy.measure.ex` | 528–559 | os, cpu, arch, cores | `:os.type`, `uname`, `sysctl`, `/proc/cpuinfo`, `:erlang.system_info` |
| `lib/mix/tasks/awfy.measure_xmpp.ex` | 237–269 | os, cpu, arch, cores | identical to above (cloned) |
| `lib/mix/tasks/awfy.preflight.ex` | 95, 114–116, 127–128, 441, 450, 526–551 | cpu brand, core count, memory, load avg | `sysctl`, `/proc/cpuinfo` |
| `lib/mix/tasks/awfy.fill.ex` | 116, 203, 243 | platform, install dispatch | `:os.type`, `:erlang.system_info(:system_architecture)` |
| `lib/awfy/peer_runner.ex` | 163 | win32 check | `:os.type` |
| `lib/awfy/fill/diff.ex` | `detect_platform/2` (pure) | platform classification | takes os.type as input |
| `lib/awfy/preflight/parse.ex` | 165–185 | cpuinfo parsers (shared!) | pure |

### Observations

- `Preflight.Parse.cpuinfo_field/2` (parse.ex:163–177) and `cpuinfo_count/1` (parse.ex:179–185) are the only pure parsers; they're already shared by `measure.ex` and `measure_xmpp.ex` (good).
- But `cpu_string/0` and `os_string/0` aren't shared — each writer wraps the parsers with the same `trim_cmd/2` and the same `case :os.type() do` dispatch (measure.ex:528–552, measure_xmpp.ex:237–262 — byte-identical, different module scope).
- `preflight.ex:115` does `sysctl_int("hw.ncpu")` for cores count, but `measure.ex:332` uses `System.schedulers_online()` for cores. On a host with `+S 2` limiting schedulers, preflight and meta.json will disagree about core count.
- `fill.ex:116` calls `Diff.detect_platform/2`, but the result (e.g. `"linux-x86_64"`) never makes it into `meta.json`. The dashboard derives `platform` from `meta["machine"]["os"]` + `meta["machine"]["arch"]` indirectly. Two sources of truth, one read at run time, one written at run time, nothing checks they agree.

### Proposed refactor

Introduce `Awfy.Measure.Machine` (`lib/awfy/measure/machine.ex`) with one entry point:

```elixir
@spec describe() :: %{
        hostname: String.t(),
        os: String.t(),
        cpu: String.t(),
        arch: String.t(),
        cores: pos_integer(),
        platform: String.t()          # canonical "linux-x86_64", "macos-arm64", "windows-x86_64"
      }
def describe(), do: %{...}
```

- Move `os_string`, `cpu_string`, `trim_cmd`, `:inet.gethostname` call all into here.
- Have `Awfy.Fill.Diff.detect_platform/2` consume `Machine.describe/0`'s output (or be folded in if its only caller stops being `fill.ex`).
- Have `Awfy.Preflight` consume `Machine.describe/0`'s `cores` field instead of running its own `sysctl_int("hw.ncpu")` — fixes the `+S 2` disagreement above.
- Have `Awfy.Measure.Meta` (§1) consume `Machine.describe/0`.
- Add `platform` as a new top-level meta field. Currently derived in the dashboard but never written; making it explicit collapses one more source of disagreement.

Migration order:

1. Build `Machine.describe/0` from the existing implementations.
2. Replace measure.ex and measure_xmpp.ex copies with the call.
3. Replace preflight's `sysctl_int("hw.ncpu")` cores read.
4. Fold `Diff.detect_platform/2`'s logic in.

**Effort: small (~150 lines including deletion of the duplicates).**

---

## 5. Topology + stats sampling abstraction

### Problem

`lib/awfy/xmpp/topology.ex` and `lib/awfy/xmpp/docker_stats.ex` are XMPP-specific by name but their structure is generic — `Topology` is "deploy/wait_ready/teardown" with `:local`/`:aws_clt` variants, `DockerStats` is "sample one metric source until deadline, return parallel sample lists". The user signaled future plans for network-bench with its own topology (`PLAN/NETWORK_BENCH_PLAN_TIER1.md`) and for swapping docker-stats for a Prometheus scrape (docker_stats.ex:87–91 explicitly anticipates this for Phase 4).

### Current shape

`Topology`:
- `deploy(:local | :aws_clt, %ScenarioConfig{}) :: {:ok, State.t()} | {:error, term()}` — generic enough.
- `wait_ready(state, timeout_ms)` — currently does three XMPP-specific stages (broker, CETS, amoc); not generic.
- `teardown(state)` — generic.
- `State.t()` carries XMPP-specific fields: `broker_host`, `broker_port`, `broker_containers`, `amoc_master_container`, `amoc_worker_container`. A network-bench topology would have different fields entirely.

`DockerStats`:
- `sample_until(containers, deadline) :: {[cpu_pcts], [mem_mbs]}` — the cluster-aggregate behaviour (sum across containers, parallel reads) is XMPP-specific (docker_stats.ex:73–98 cluster-aggregate convention).
- Parsing helpers (`parse/1`, `parse_cpu/1`, `parse_mem/1`) are docker-stats-specific format-string parsers.

### Bug surface

- `Awfy.Xmpp.Runner.broker_containers/1` (xmpp/runner.ex:167–171) has a fallback path that hard-codes `["awfy-mongooseim-1"]` for legacy states. A single point where the cluster-vs-single-broker mismatch could silently halve the recorded CPU%/mem.
- `Topology.wait_amoc_cluster/2` (topology.ex:219–236) is named generically but is hard-bound to `amoc_master_container`, which doesn't exist in a non-XMPP topology. Misleading — should be `wait_load_generator_cluster` in spirit.

### Proposed refactor: two behaviours

**`Awfy.Topology` behaviour:**

```elixir
@callback deploy(config :: map()) :: {:ok, state :: term()} | {:error, term()}
@callback wait_ready(state :: term(), timeout_ms :: pos_integer()) :: :ok | {:error, term()}
@callback metric_sources(state :: term()) :: [Awfy.MetricSource.t()]
@callback teardown(state :: term()) :: :ok
```

Implementations: `Awfy.Topology.XmppLocal`, `Awfy.Topology.XmppAwsClt`, future `Awfy.Topology.NetworkLocal`. Each owns its state struct and exposes only the behaviour callbacks.

**`Awfy.MetricSource` behaviour:**

```elixir
@callback sample_until(source :: term(), deadline_ms :: integer()) :: %{cpu_pct: [float()], mem_mb: [float()], throughput: [number()] | nil}
@callback supported_metrics(source :: term()) :: [:cpu_pct | :mem_mb | :throughput | atom()]
```

Implementations: `Awfy.MetricSource.DockerStats` (current), future `Awfy.MetricSource.Prometheus`, future `Awfy.MetricSource.CloudWatch`. Each returns a uniform per-second sample map; the runner doesn't care which one ran.

The `Awfy.Xmpp.Runner.sample/3` (xmpp/runner.ex:142–158) shrinks to a generic `Awfy.AppBench.Runner.sample` that iterates `Topology.metric_sources(state)`, calls `MetricSource.sample_until/2` on each, merges the maps, and hands them to `Awfy.AppBench.Result.build_multi/2` (which already accepts a list of `{name, samples, opts}` tuples — no changes at the boundary).

XMPP-specific `wait_cets_cluster/2` (topology.ex:153–172) and `wait_amoc_cluster/2` (topology.ex:219–236) become private callbacks of `XmppLocal`, not part of the public behaviour. Cleaner separation.

### Migration order

1. Define the two behaviours in `lib/awfy/topology.ex` and `lib/awfy/metric_source.ex`.
2. Make `Awfy.Xmpp.Topology` and `Awfy.Xmpp.DockerStats` implement them (mechanically; public functions already match).
3. Update `Awfy.Xmpp.Runner` to call through the behaviours by tag rather than by direct module reference.
4. Move `lib/awfy/xmpp/topology.ex` → `lib/awfy/topology/xmpp_local.ex` (rename to reflect that this is one implementation, not THE topology).
5. Document the network-bench Phase 2 path as a second implementer.

**Effort: medium (~300 lines for behaviours, renames, adapter glue).**

---

## 6. Measure mix tasks — shared scaffolding

### Problem

`mix awfy.measure`, `mix awfy.measure_xmpp`, `mix awfy.fill`, `mix awfy.diff` all share a common opening sequence — option parsing, label resolution, dir setup, git-state probe, output-dir clobber handling, meta.json write — but each task reimplements it.

### Inventory

| Step | `awfy.measure` | `awfy.measure_xmpp` |
|---|---|---|
| Compile | line 78 | line 50 |
| Parse opts | line 80 | line 52 |
| git_state | line 86 + helper 273–284 | line 57 + helper 224–235 (cloned) |
| auto_label | line 87 (via Helpers) | line 58 (via Helpers) — good, shared |
| run_dir | line 91 (via Helpers) | line 62 (via Helpers) — good, shared |
| Clobber check | lines 100–109 | lines 108–119 (cloned) |
| Compile preflight | line 82–84 | (not done; XMPP doesn't preflight) |
| Write meta | line 314 | line 169 |

The `git_state/0` clones at `measure.ex:273–277` and `measure_xmpp.ex:224–228` are byte-identical. The `git/1` helper inside them is also byte-identical. The clobber dance (`File.exists?(dir) → no_clobber raise OR rm_rf! warn → mkdir_p!`) is a paragraph reimplemented as `prepare_dir/2` in xmpp (measure_xmpp.ex:108–119) and inlined in measure.

### Proposed refactor

Two options:

**(A) `Awfy.Measure.Task` macro (`use Awfy.Measure.Task`).** Provides Mix.Task boilerplate, a `prepare_run/2` callback that builds the `RunContext` + clobber-checks the dir, and a `write_meta/2` hook. Pattern similar to `Phoenix.Channel` or `Plug` — boilerplate-elimination via a macro.

Pros: very small task implementations.
Cons: macros are slightly opaque; debugging stack traces gets murky.

**(B) Plain `Awfy.Measure.Setup` function helpers.** A behaviourless module with `parse_common_opts/1`, `prepare_run_dir/2`, `build_run_context/2`. Tasks call them in their `run/1` body without a macro.

Pros: stays imperative, easy to read.
Cons: more boilerplate per task than (A).

Given the small number of tasks (currently 2, projected 3-4) and the high cost of macro debugging, **option (B) is the better fit**. The macro pays off at ~5+ tasks; nowhere near.

Concretely:

- New module `Awfy.Measure.Setup`:
  - `parse_common_opts(args, extra_switches) :: {opts, rest}` — pulls `--label`, `--out`, `--no-clobber` consistently.
  - `prepare_run_dir(opts, scenario_tag) :: {:ok, dir, run_context}` — runs `git_state`, `auto_label`, `run_dir`, clobber dance, mkdir.
- `Awfy.Measure.Meta` (§1) — final step every task calls before exit.

Migration order:

1. Land `Awfy.Measure.Setup`.
2. Convert `awfy.measure_xmpp.ex` first (simpler, ~50 lines saved).
3. Convert `awfy.measure.ex` (~80 lines saved including the duplicate git/os/cpu helpers).
4. Convert future `awfy.measure_network` natively against the helpers.

**Effort: small-medium (~150 lines new + ~200 lines deleted across the two tasks).**

---

## 7. Smoke-test gaps

### Problem

The existing smoke (`test/versioned_bench_test.exs`) asserts only "the task didn't crash" + "the meta.json has these fields" + "an HTML file exists". Three classes of bug have shipped past this fence:

- meta.json schema drift (XMPP omits `runtime`/`config` — see §1).
- benchee scenario name pattern mismatches (the `xmpp_cpu/erlang` vs `Bounce/erlang` vs `phash2` triplet — see `Awfy.Compare.Data.identify_scenario/3` data.ex:280–300, regression history at data.ex:271–279).
- silent emu_flavor mistag (data.ex:173–180, fixed in dashboard but never asserted at write time).

### Proposed assertions

**Unit-test layer (`test/measure/`, runs on every push):**

1. **Schema validation.** A single `Awfy.Measure.MetaSchema.validate/1` function (proposed §1) + a test that calls every writer with stub inputs and feeds the result through the validator. Replaces the field-by-field `assert meta["x"]` blocks in versioned_bench_test.exs:46–82 with one schema check.
2. **Scenario-name pattern regression.** Assert every benchmark name `Awfy.BencheeRunner` produces matches `~r/^[A-Z][a-zA-Z]+\/(erlang|elixir)$/`; every OtpBenchmarks family produces `~r/^[a-z][a-z0-9_]+$/` with `input_name` populated; every XMPP scenario produces `~r/^xmpp_(cpu|mem|speed)\/erlang$/`. Pin the family of patterns so a name-format drift fails a fast unit test rather than silently demoting a row's `lang` field to `nil` in the dashboard.
3. **Bundle-path / peer-path equivalence.** A property-style test: pick a benchmark, run it in-process (via `AWFY_NO_ISOLATION=1`) and via the bundle path, assert the two `.benchee` files have the same scenario count + the same scenario names. Catches the `adjust_for_batching` drift between `target_runner.ex:297–343` and `otp_benchmarks/runner.ex:234–279` (§2).

**CI smoke layer (`test/smoke/`, runs in the dashboard-only CI lane and in the bench workflow's gate step):**

4. **Run-dir invariant.** For each measure task's output: exactly one `meta.json` + at least one `.benchee` file; no other top-level files. Catches a task accidentally writing two meta files or accidentally writing intermediate artifacts.
5. **Dashboard render snapshot.** After `mix awfy.compare`, assert:
   - `index.html` exists and contains a `<tr>` row for each major OTP version present in the run set.
   - `stability.html` exists and contains a `data-platform=` attribute on every row.
   - `per-bench/<bench>.html` exists for each unique `bench_name` produced; for XMPP runs, `per-bench/xmpp_cpu.html` contains `data-samples=` (sparkline data — currently rendered at compare.ex:714 — only way to verify per-second sample propagation end-to-end).
   - `index.html` contains a numeric geomean for each major. Catches the case where one row's missing `median_ms` collapses the whole bucket's geomean to `nil`.
6. **End-to-end run shape**: a CI-only test that runs `mix awfy.measure --time 0.1 --warmup 0`, then `mix awfy.measure_xmpp` with a stub topology (could shim `Awfy.Topology.XmppLocal` to a no-op `Awfy.Topology.Fixture`), then `mix awfy.compare`, then asserts (4) + (5).

### Where each assertion lives

| Assertion | Location | Why |
|---|---|---|
| Schema validator | `test/measure/meta_schema_test.exs` (unit) | Fast — runs on every push, no Mix.Task.rerun cost. |
| Scenario-name patterns | `test/measure/scenario_names_test.exs` (unit) | Same. Doesn't need the actual measure task. |
| Bundle/peer parity | `test/runner_parity_test.exs` (unit, marked `@tag :slow`) | Requires running both paths once. ~30 s. |
| Run-dir invariant | `test/smoke/run_dir_test.exs` (CI smoke) | Needs the actual file output of a real measure task. |
| Dashboard render | `test/smoke/dashboard_render_test.exs` (CI smoke) | Needs `mix awfy.compare` against real output. |
| E2E shape | `test/smoke/e2e_test.exs` (CI smoke) | Full chain — only meaningful in CI. |

The split is "anything that can run from stubbed input belongs in unit tests, anything that needs the file output of a real `Mix.Task.rerun` belongs in `test/smoke/`". The dashboard-only CI lane (`8b228e8c` in the recent history) already gates that distinction at the workflow level.

### Bonus: assertions that would have caught past bugs

- **`meta["runtime"] != %{}` for every writer.** Would have flagged the XMPP `runtime` omission (§1) the day it landed.
- **`length(scenarios in .benchee) == length(meta["benchmarks"]) + sum(length(otp_benchmarks_meta[*].scenarios))`** — would have caught the OtpBenchmarks-vs-AWFY filter no-op landing wrong when filter contains only OtpBenchmarks names (measure.ex:121–140 history).
- **`flavor_from_label(meta["label"]) == meta["runtime"]["emu_flavor"]`** when both are present — would forbid the silent disagreement at data.ex:181 from ever recurring, surfacing instead as a write-time test failure pointing at the offending writer.

**Effort: medium (~400 lines new test code, ~50 lines new schema module).** None requires modifying production code, so the smoke layer can land independently of §1–§6.

---

## Cross-references

- `PLAN/MONGOOSEIM_BENCH_PLAN.md` § Phase 4 references the docker-stats → Prometheus migration; §5 here is the structural prerequisite.
- `PLAN/NETWORK_BENCH_PLAN_TIER1.md` describes the second `Awfy.Topology` implementer (§5).
- `PLAN/TARGET_ELIXIR_RUNNER_PLAN.md` decision #10 explicitly argues against making `awfy_target_runner` a path-dep — §2's codegen approach respects that.
- `ARCHITECTURE.md` should pick up `RunContext` (§3) as the single object describing "what ran" once the refactor lands.
