<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# MongooseIM Bench Plan — XMPP application-level workload

Companion to `EXTENDED_BENCH_PLAN.md` (OTP-primitive families) and
`NETWORK_BENCH_PLAN_TIER1.md` (single-host distribution + TLS). Adds
a *real-application* axis to the dashboard: a pinned MongooseIM
broker driven by Amoc as the load generator, surfacing how each OTP
version handles a workload representative of how the BEAM actually
gets used in production.

Where the AWFY compute suite catches JIT / inner-loop regressions
and the OtpBenchmarks families catch BIF / map / phash2 regressions,
this benchmark catches the convolution: scheduler under message-pass
load, ETS contention from real session stores, binary handling in
XML, gen_server hot-paths, TLS CPU cost — all at once, end-to-end,
through a real Erlang application that the ecosystem actually runs.

## Why this and not the alternatives

Three real-app benchmark candidates were considered:

* **TechEmpower / the-benchmarker / Sharkbench** — external load
  driver (wrk) + separate server + (usually) PostgreSQL container.
  Fundamentally a different test rig than AWFY's harness. Adopting
  one means owning a second rig, not "porting a benchmark."
* **RabbitMQ + PerfTest** — adds a Java dependency on every test
  host (PerfTest is a Java jar) and requires per-ref broker builds.
  ~Multi-week integration. Genuinely a flagship-tier benchmark but
  the toolchain mismatch is heavy.
* **ejabberd / MongooseIM + Amoc** — this plan. Erlang-native end
  to end (Amoc is itself an Erlang OTP app), aligns with our existing
  peer-runner architecture, ESL maintains it so internal expertise
  is high, and the per-ref-build pattern slots into the existing
  `bin/install-otp-source-mac.sh` / `Dockerfile.linux` pipelines.

bencherl-style OTP-primitive ports (a separate workstream, see
`EXTENDED_BENCH_PLAN.md` extension) are NOT a replacement for this —
they cover *primitives under contention*, not *applications under
load*. The two answer different questions.

## Goals

1. **One pinned MongooseIM commit, multiple OTP versions** — isolate
   the OTP performance delta from MongooseIM evolution. Same pinning
   model as the AWFY suite source, the legacy Elixir-per-major pins,
   and the OtpBenchmarks vendored sub-app.
2. **Erlang-native test rig** — Amoc is the load generator, runs as
   a peer Erlang node, same shape as `Awfy.BencheeRunner`'s isolated
   peer mode. No Java, no external load tool, no separate Docker
   stack for the driver.
3. **Best-effort coverage from OTP-26 up** — MongooseIM's current
   `rebar.config` requires OTP 26+ (one of its deps, `worker_pool`,
   has `{minimum_otp_vsn, "26"}`). Legacy refs (20–25) are out of
   scope; dashboard already handles missing data.
4. **Result schema friendly to the dashboard** — Amoc reports
   throughput (msg/s) and latency percentiles. Map into the existing
   `.benchee`-compatible row shape so the trend chart + stability
   page work without compare-flow changes.
5. **Patch-when-master-breaks discipline** — when an OTP master
   change breaks the MongooseIM build, ship a small compat patch
   under `patches/mongooseim-<pin>/` rather than skipping the leg.
   Patches don't need to be upstream-quality; they just need to keep
   the bench building.

## Non-goals

* **Replacing the in-process AWFY / OtpBenchmarks suites.** Those
  catch a different class of regression (tight loops, BIF cost) at
  fractional runtime cost. This benchmark is one (slow, end-to-end)
  data point per ref, not 200 micros.
* **GHA-runner-based measurement.** Shared-tenancy noise + no way
  to deploy a 6-VM topology from inside a single runner. AWS multi-
  instance is the production measurement topology; local single-node
  is a first-class dev / smoke target but its numbers don't go to
  the public dashboard.
* **Headline dashboard placement.** Doesn't replace the geomean line.
  Adds to the snapshot card + a dedicated section.
* **Sub-second-resolution latency tracking.** Per-message tail
  latency interesting but not the regression signal we care about
  for OTP commits; throughput + p99 is enough.

## Architecture

Scenarios are upstream amoc-arsenal-xmpp modules consumed unchanged
— we don't write our own. The Amoc Docker image ships them at the
pinned commit, and our runner configures them via env vars
(`MONGOOSE_HOST`, `USERS`, `DOMAINS`, `INTERARRIVAL_MS`, etc.) that
are interpreted by `amoc_config_env`. Same scenario module runs
unchanged against `:local` (Amoc workers in-VM) and `:aws_clt`
(distributed Amoc master + 2 workers); only the env-var values
differ. The runner resolves topology from a config tag and handles
deploy / wait / drive / teardown.

```
host (modern Elixir/OTP)
    Mix.Tasks.Awfy.Measure
        │
        ├─ AWFY suite      → Awfy.BencheeRunner          (per-bench scenarios)
        ├─ OtpBenchmarks   → Awfy.OtpBenchmarks.Runner    (per-family scenarios)
        └─ XmppBroker       → Awfy.Runner.XmppBroker       (NEW, OTP ≥ 26)
                                       │
                                       ├─ Topology.deploy(topology_tag, target_erl, mongoose_release)
                                       │     → {brokers, amoc_master, amoc_workers, auth_backend}
                                       │
                                       ├─ Topology.wait_until_ready({brokers, auth_backend})
                                       │
                                       ├─ Amoc.run(amoc_master, scenario_module, duration)
                                       │     → {throughput, percentiles}
                                       │
                                       └─ Topology.teardown(topology)
```

**Everything runs in Linux containers.** MongooseIM is packaged as a
Docker image built FROM the existing per-ref OTP image (the one
`build-linux` in `bench.yml` already produces). Amoc ships as a
sibling image. Two consequences:

* **Linux-only for this benchmark.** macOS local-dev runs the same
  containers via [Colima](https://github.com/abiosoft/colima)
  (`brew install colima docker docker-compose` + `colima start
  --cpu 4 --memory 8 --vm-type vz --mount-type virtiofs`) — the
  BEAM-under-test is Linux even on the M5. Aligns with the
  production target (servers run Linux) and removes the
  macOS-source-build branch entirely for MongooseIM. Docker Desktop
  works too but isn't required and isn't what the maintainer uses.
* **Per-ref MongooseIM image reuses the per-ref OTP build.** No
  parallel build pipeline; we add one stage to the existing image,
  cache it the same way (`ghcr.io/<repo>:<otp_sha>-mongoose`).

### Topology: `local`

Default for dev/smoke work. `docker compose up` brings up one
MongooseIM container + one Amoc container on a shared bridge
network. Runs on a laptop or a GHA runner identically.

```
[ docker host (laptop / GHA / AWS-spot - all Linux containers) ]
  ┌──── network: awfy-xmpp ────────────────────────────┐
  │                                                     │
  │  mongooseim-1 (port 5222)    ← per-ref MIM image    │
  │     auth + sessions: in-memory Mnesia                │
  │                                                     │
  │  amoc-master (in-VM workers) ← amoc image           │
  │     connects to mongooseim-1:5222                    │
  └─────────────────────────────────────────────────────┘
```

* Cost: zero infrastructure.
* What's measured: BEAM internals under XMPP workload — message
  routing, ETS session lookups, binary handling on stanzas, TLS CPU
  (if enabled). Distribution + RDS not exercised.
* Where the result lands: **dev / smoke only**. Locally-collected
  numbers may go to a `dev/` namespace on gh-pages for the user's
  own browsing; they don't ship to the public dashboard's main line.
* Topology config: `topology_tag = :local`, compose file
  `priv/topology/local.compose.yml`.

### Topology: `aws_clt`

Production measurement topology, matches ESL's CLT shape:

```
                                 ┌──── RDS PostgreSQL ────┐
                                 │   (db.m6g.xlarge)      │
                                 │   auth + persistence   │
                                 └──────────▲─────────────┘
                                            │
                ┌───────────────────────────┼────────────────────────────┐
                │                           │                            │
        MongooseIM-1               MongooseIM-2                MongooseIM-3
        (c5ad.xlarge)              (c5ad.xlarge)              (c5ad.xlarge)
        port 5222 ◄────── cluster (distribution) ──────────► port 5222
                ▲                           ▲                            ▲
                └───────────────────────────┼────────────────────────────┘
                                            │ XMPP connections (TLS)
                                            │ 1k-50k connected users
                                            │
                                  ┌─────────┴─────────┐
                                  │                    │
                          amoc-worker-1       amoc-worker-2
                          (c5.xlarge)         (c5.xlarge)
                                  ▲                    ▲
                                  └────── peer ────────┘
                                    distribution
                                          │
                                    amoc-master
                                    (c5.xlarge)
                                    receives results
                                          │
                                          ▼
                                     Awfy.Runner.XmppBroker
                                     (lives on the AWFY orchestrator)
```

* Same scenario code as `local`, but with 2 workers distributing
  N connected users instead of 1 in-VM worker doing all of them.
* Auth backend is RDS Postgres — exercises Postgrex driver + actual
  network roundtrips that production users see.
* MongooseIM nodes cluster via Erlang distribution; session
  replication or shared-state backend per the pinned MongooseIM
  default config.
* Cost (us-east-1 on-demand): ~$1.40/hr for the EC2 + RDS bundle.
  Per measurement (~25 min including spin-up + 8.3 min ramp at 5 ms
  interarrival × 100k users + 10 min steady-state + teardown)
  ≈ **$0.60 per OTP ref**. Full sweep across OTP 26/27/28/maint/
  master: ~$2.50-3.00.
* Where the result lands: the main public dashboard, under an
  `xmpp/<scenario>` series in the trend chart + a dedicated
  snapshot card section.
* Topology config: `topology_tag = :aws_clt`, broker count = 3,
  worker count = 2, auth_backend = `{:postgres, %{...rds...}}`.

### Deployment

`:local` deploys via `docker compose` from a checked-in
`local.compose.yml`. The runner runs `compose up -d`, polls for
broker readiness, runs the scenario via the Amoc container, then
`compose down`. No external infrastructure.

`:aws_clt` deploys to EC2-with-Docker (or ECS if the IAM cost
is acceptable). Terraform module — or ESL's existing CLT scaffolding
if reusable — provisions the 6 EC2 instances + RDS, installs Docker,
runs the same MongooseIM image we built for `:local`, plus an `ecs
compose`-style YAML pinning each container to a specific instance.

In both cases the topology orchestrator writes a `topology.json`
artifact with broker hostnames, RDS DSN, Amoc master node name.
The AWFY orchestrator's `measure` step reads that and connects —
identical code path regardless of whether the topology lives on
`docker0` or in a VPC. This keeps the orchestrator testable locally
without needing AWS credentials in the test path.

### File layout

```
Docker images (cached in ghcr.io/<repo>:<tag>)
  ghcr.io/<repo>:<otp_sha>-x86_64                  ← existing per-ref OTP image
  ghcr.io/<repo>:<otp_sha>-mongoose                ← NEW, FROM the OTP image above
  ghcr.io/<repo>:amoc-<amoc_pin>                   ← OTP-agnostic, built once per pin

Dockerfile.mongoose                                  ← new
  FROM ghcr.io/<repo>:<otp_sha>-x86_64
  COPY patches/mongooseim-<pin>/ /tmp/patches/
  ... fetch MIM at $MIM_PIN, apply patches, make rel ...
  ENTRYPOINT ["/opt/mongooseim/bin/mongooseimctl", "foreground"]

Dockerfile.amoc                                      ← new, OTP-agnostic base
  FROM erlang:27-alpine
  ... fetch Amoc + arsenal + Escalus at pinned refs, rebar3 release ...
  ENTRYPOINT ["/opt/amoc/bin/amoc", "console"]

lib/awfy/xmpp/                                       ← orchestrator code in root app
  topology.ex                                          deploys :local (compose), connects
                                                       to :aws_clt (reads topology.json)
  runner.ex                                            deploy → wait → run → teardown
  scenario_config.ex                                   reads priv/scenario-config/*.json
lib/awfy/app_bench/                                  ← generic helpers, door-open shared
  result.ex                                            throughput+percentiles → .benchee row
priv/topology/
  local.compose.yml                                    docker-compose for :local
  aws_clt.tf.example                                   Terraform reference for :aws_clt
priv/scenario-config/
  dynamic_domains_pm.local.json                        users=1k, domains=10, ia=5ms
  dynamic_domains_pm.aws_clt.json                      users=100k, domains=1k, ia=5ms
lib/mix/tasks/
  awfy.measure_xmpp.ex                                 mix task entry point

bin/ensure-docker.sh                                 ← macOS: start Colima if needed,
                                                      stop it on exit if we started it
priv/mongooseim-pin.txt                              ← MongooseIM git tag
priv/amoc-pin.txt                                    ← Amoc git tag
priv/amoc-arsenal-pin.txt                            ← scenarios git tag
priv/amoc-otp-version.txt                            ← OTP the load-gen runs on
patches/mongooseim-<pin>/*.patch                     ← compat patches when master breaks
```

## OTP × MongooseIM × Amoc pins

Every third-party piece is pinned. The only axis that varies across
the dashboard is the broker's OTP version.

| Pin | File | Value | Why |
|---|---|---|---|
| MongooseIM | `priv/mongooseim-pin.txt` | git tag (e.g. `6.x.y`) | Same MongooseIM on every OTP; isolates OTP delta from MongooseIM evolution. |
| Amoc | `priv/amoc-pin.txt` | git tag | Same load-generator semantics. |
| Amoc's OTP | `priv/amoc-otp-version.txt` | e.g. `27.3` | Load-gen environment held constant — only the broker's OTP varies. |
| amoc-arsenal-xmpp | `priv/amoc-arsenal-pin.txt` | git tag | Pinned scenarios. |
| Escalus | (transitive via Amoc lock) | — | No separate pin; whatever Amoc's lockfile says. |

**Pin refresh discipline:** annual cadence by default, opportunistic
when OTP master breaks the build for long enough that patching is no
longer "small." All four files bump together in a single
"pin-refresh-YYYY" PR so the dashboard discontinuity is one event,
not four. The refresh PR documents which scenarios are affected and
the dashboard surfaces the pin change as a chart annotation. The
prior pin can be kept running for one ref cycle alongside the new
one when the change is large.

## Components to build

### 1. `Dockerfile.mongoose` (per-OTP-ref MongooseIM image)

Multi-stage: `FROM ghcr.io/<repo>:<otp_sha>-x86_64` (the existing
per-ref OTP image `build-linux` already builds), `COPY` the
`patches/mongooseim-<pin>/` dir, fetch MongooseIM at the pin,
apply patches, `make rel`, strip dev artifacts, set the entrypoint
to `mongooseimctl foreground`. Image tag:
`ghcr.io/<repo>:<otp_sha>-mongoose`.

Build trigger: new GHA job `build-mongoose-image`, gated on
`has_xmpp_bench == 'true'` (a new resolver output that mirrors the
existing `has_legacy_build`). Cache key: `(otp_sha, mim_pin,
patches/mongooseim-<pin>/ hash)`. Subsequent runs against the same
SHA hit GHCR's image cache.

Configure-rel opts strip everything we don't need: HTTP frontend,
MAM, MUC — keep only auth + presence + c2s. Smaller image, faster
boot, less to break on a pin refresh.

### 2. `Dockerfile.amoc` (load-gen image, OTP pinned)

Single image, **does not** vary by target OTP. The load generator's
OTP version is pinned alongside Amoc itself — we want the
load-gen environment constant across the matrix so any cross-OTP
delta we observe is the *broker's* OTP, not the client side's. Same
principle as pinning MongooseIM: only one axis varies at a time.

`FROM erlang:${AMOC_OTP_VERSION}-alpine` where `AMOC_OTP_VERSION`
comes from `priv/amoc-otp-version.txt` (e.g. `27.3`). Fetch
Amoc + amoc-arsenal-xmpp + Escalus at their pins, rebar3 release,
entrypoint `amoc console`. Image tag:
`ghcr.io/<repo>:amoc-${AMOC_OTP_VERSION}-${AMOC_PIN}`.

Build trigger: rebuilt only when one of `priv/amoc-pin.txt`,
`priv/amoc-otp-version.txt`, or the Dockerfile changes. Yearly
pin-refresh PR bumps these together with the MongooseIM pin so
the discontinuity on the dashboard is one event, not three.

### 3. `patches/mongooseim-<pin>/` directory

Same shape as `patches/OTP-<vsn>/`. Per-pin directory with numbered
`.patch` files. Applied by `Dockerfile.mongoose` after fetch, before
build. Empty when MongooseIM builds clean against every OTP in the
matrix; populated when an OTP master change breaks compat and we
ship a small `s/old_api/new_api/g`-style fix to keep the bench
building.

Patches are forward-apply only. When MongooseIM upstream merges its
own fix, we delete the patch on the next pin refresh.

### 4. Local-topology docker-compose

`priv/topology/local.compose.yml`:

```yaml
services:
  mongoose:
    image: ghcr.io/<repo>:${OTP_SHA}-mongoose
    ports: ["5222:5222"]
  amoc:
    image: ghcr.io/<repo>:amoc-${AMOC_PIN}
    depends_on: [mongoose]
    environment: { MONGOOSE_HOST: mongoose }
```

`OTP_SHA` and `AMOC_PIN` are passed from the runner. Bringing the
topology up is a `docker compose up -d mongoose && wait && docker
compose up -d amoc`; teardown is `docker compose down`.

### 5. `Awfy.Runner.XmppBroker` family

New module under `lib/awfy/runner/`, sibling to the existing
`Awfy.Runner`. Responsibilities:

* `start_broker(opts)` — fork the target's `mongooseimctl foreground`
  with a port file, wait for `5222` to accept TLS.
* `run_scenario(scenario_module, duration_ms)` — spawn the peer
  Amoc node, load the scenario, run it for `duration_ms`, collect
  the per-second sample stream.
* `stop_broker(broker_state)` — `mongooseimctl stop`, kill if it
  doesn't exit within `STOP_TIMEOUT_MS`.

Scenarios are upstream amoc-arsenal-xmpp modules baked into the
Amoc Docker image at the pinned commit (e.g. `dynamic_domains_pm`).
We don't author scenario code — the arsenal scenarios already
parametrise their behaviour via `amoc_config_env`, so the
per-topology JSON config maps directly onto `os:getenv/1` values
the Amoc container reads.

### 6. Phase 1 scenario: `dynamic_domains_pm`

Use the existing arsenal scenario `dynamic_domains_pm` from
[amoc-arsenal-xmpp](https://github.com/esl/amoc-arsenal-xmpp) at the
pinned commit. Point-to-point messaging across many dynamic XMPP
domains — exercises the vhost / domain-lookup subsystem, cross-domain
message routing, ETS session table at scale, roster + presence
hot-paths.

**Parameters per topology:**

| Topology | Users | Domains | Interarrival | Why |
|---|---|---|---|---|
| `:aws_clt` | 100,000 | 1,000 | 5 ms | ESL CLT production-shape. Ramp ≈ 8.3 min (100k × 5ms), then measure for ~10 min steady-state. |
| `:local` | 1,000 | 10 | 5 ms | 100× scale-down so an M5 / laptop can host the whole thing in a Colima VM (or any Docker-CLI-providing runtime). Ramp ≈ 5 s, measure ≈ 60 s. Smoke / dev only — numbers don't ship to the public dashboard. |

Scenario parameters live alongside the topology configs:

```
priv/scenario-config/
  dynamic_domains_pm.aws_clt.json   # users=100000, domains=1000, interarrival_ms=5
  dynamic_domains_pm.local.json     # users=1000,   domains=10,   interarrival_ms=5
```

Result columns: median per-message latency (period_per_msg_ns),
p50/p99 latency, total messages delivered during the measurement
window. Throughput is `1_000_000_000 / median_ns` — derived for
display but the row stores latency to keep the existing
"lower = faster" dashboard convention.

Second scenario (Phase 3) is currently undecided; ESL's arsenal has
`mongoose_one_to_one` (single-domain, simpler routing) and
`mongoose_pubsub` (broadcast hot-path) as natural complements. Pick
after Phase 1 surfaces what `dynamic_domains_pm` *doesn't* show.

### 7. Result schema

Amoc's per-second sample stream maps to a `.benchee`-equivalent
shape so `Awfy.Compare.Data.load/2` reads it without modification:

```
%Benchee.Suite{
  scenarios: [
    %Benchee.Scenario{
      name: "dynamic_domains_pm",
      run_time_data: %{
        statistics: %{
          # period_per_msg in nanoseconds — 1/throughput, so the
          # dashboard's "lower = faster" convention holds.
          median: <period_ns>,
          percentiles: %{25 => <p25_ns>, 75 => <p75_ns>, ...},
          sample_size: <messages_sent>
        },
        samples: [<one entry per Amoc 1s sample window>]
      }
    }
  ]
}
```

`Awfy.Compare.Data` already supports arbitrary scenario names —
"XmppBroker/dynamic_domains_pm" lands on the dashboard alongside other
benchmarks. May want a dedicated `scenario_group` ("xmpp") for
filter UI on the stability page; one-line addition in
`lib/mix/tasks/awfy.compare.ex:scenario_group/1`.

## Phased rollout

### Phase 1: local topology end-to-end

Prereq on the dev machine: a Docker runtime exposing the standard
socket. Maintainer uses **Colima** on macOS arm64 (`brew install
colima docker docker-compose`); any equivalent (Docker Desktop,
Podman, OrbStack) works since we only use the `docker` CLI surface.

**Scripts manage Colima's lifecycle on macOS.** Linux is assumed to
already have Docker available (it's the GHA / AWS runner OS — the
daemon is part of the host setup); only macOS dev machines need
auto-lifecycle handling.

On macOS, the runner and `bin/measure-all-macos.sh` source a shared
helper `bin/ensure-docker.sh` that:

1. If `colima status` reports running, no-op — user pre-started it,
   leave the lifecycle alone (fast iterative dev).
2. Otherwise `colima start --cpu 4 --memory 8 --vm-type vz
   --mount-type virtiofs` and record that we started it via a
   touch-file at `$TMPDIR/awfy-started-colima`.
3. Install an `EXIT` trap in the parent script: if the touch-file
   exists, `colima stop` — we started it, we stop it. If it
   doesn't (user already had it running), leave Colima alone.

On Linux the helper is a no-op `return 0`.

This means iterative dev (`colima start` once at the beginning of
the day) gets fast benchmark iterations; one-shot scripts (CI,
`measure-all-macos.sh` invoked from a cron) start cold and clean up
after themselves. The helper is sourced, not invoked as a subshell,
so the exit-trap is in the parent script's process.

* `Dockerfile.mongoose` builds against a public OTP base image (e.g.
  `erlang:28-alpine`) for Phase 1 — wiring it to the per-ref AWFY
  OTP images is Phase 2's concern. Single image, fixed OTP version,
  proves the MongooseIM build pipeline.
* `Dockerfile.amoc` builds against `erlang:${AMOC_OTP_VERSION}-alpine`
  with Amoc + amoc-arsenal-xmpp + Escalus at their pinned refs.
* `priv/topology/local.compose.yml` brings up
  both images on a shared bridge network.
* `Awfy.Runner.XmppBroker.run(:local, opts)` does `compose up -d`,
  polls broker readiness, drives the Amoc container to run
  `dynamic_domains_pm` at 1k users / 10 domains / 5 ms interarrival
  for ~60 s, collects per-second samples, `compose down`.
* Upstream `dynamic_domains_pm` scenario from amoc-arsenal-xmpp,
  configured via env vars in the compose file (`MONGOOSE_HOST`,
  `USERS`, `DOMAINS`, `INTERARRIVAL_MS`). No AWFY-authored scenario
  code.

**Exit criterion:** `mix awfy.measure --xmpp` runs locally, produces
a stable `xmpp/dynamic_domains_pm` row in `results/` with sub-15 %
CV across 3 consecutive runs.

**Why local first:** lets us de-risk the runner family, the
scenario API, the result schema, and the Docker image builds
without any AWS credentials or infrastructure cost. The hard parts
of the AWS path (Terraform, IAM, RDS, per-ref OTP base) are
orthogonal to the BEAM-side work and can land in parallel once
Phase 1 proves the orchestrator contract.

**Estimated effort:** ~1 week.

### Phase 2: AWS CLT topology

* Topology orchestrator (Terraform module or equivalent) provisions
  the 6-VM + RDS shape, writes `topology.json`.
* `Topology.deploy(:aws_clt, ...)` becomes a connect-not-deploy step
  — reads the json, opens distribution to the Amoc master, returns
  the same handle shape as `:local`.
* Scenario code is unchanged from Phase 1 — same `one_to_one.erl`
  binary runs against both topologies via the topology abstraction.
* `bench.yml` adds a `measure-xmpp-aws` job gated on `runner_pool=aws`
  that triggers the Terraform apply, hands `topology.json` to the
  measure step, and triggers the destroy.

**Exit criterion:** dashboard plots an `xmpp/dynamic_domains_pm`
series across OTP 26/27/28/maint/master on AWS. Per-ref median
latency stable across consecutive measurements within ~10 % CV.

**Estimated effort:** ~2 weeks. Dominated by the AWS scaffolding;
the BEAM-side code mostly reuses Phase 1.

### Phase 3: second scenario + macOS local sweep integration

* Pick a second arsenal scenario complementary to
  `dynamic_domains_pm` (candidates: `mongoose_one_to_one` for
  single-domain routing, `mongoose_pubsub` for broadcast hot-path).
* `bin/measure-all-macos.sh` extension so the M5 local sweep also
  produces `xmpp/<scenario>` rows in the dev-namespace results.
  Uses the same Colima-hosted `:local` topology as Phase 1 — the
  measure-all-macos script just `docker compose up`s it per ref.
* Windows: skip. MongooseIM doesn't claim Windows support; porting
  the build pipeline is a separate project.

**Estimated effort:** ~3 days.

### Phase 4: pin refresh discipline + observability

* Document pin refresh procedure (when to bump, how to surface the
  discontinuity on the dashboard, whether to keep old pin running
  in parallel for one cycle).
* Cron that tries to build the MongooseIM pin nightly against OTP
  master and surfaces failure as a GitHub issue. When the issue is
  open, the dashboard surfaces "MongooseIM pin doesn't build on
  master" as a per-ref annotation so missing data is intentional,
  not a silent gap.
* Topology cost telemetry — track per-measurement AWS spend so a
  noisy scenario that runs long doesn't surprise us at month-end.
* **Replace `docker stats` sampling with MongooseIM's prometheus
  endpoint.** Phase 1 / multi-broker CETS samples CPU% + mem MB via
  one `docker stats --no-stream` call per broker, parallelised — fast
  enough for the 1 sample/s cadence but coarse (container-level, not
  BEAM-level) and Docker-host-specific. Each broker already exposes
  prometheus metrics on `:9091/metrics` (`[instrumentation.prometheus]`
  in the prod-vars config). Scrape that instead:
    * `erlang_vm_memory_bytes{kind=...}` for per-subsystem memory
      (heap, binary, ets) — the dashboard sparkline gains a per-broker
      breakdown of *which* memory bucket grew across an OTP regression.
    * `erlang_scheduler_wall_time_total` deltas → CPU% (excludes the
      Postgres container's overhead, which container-CPU includes).
    * Per-broker message-queue depth + run-queue lengths as new
      sample series, plotted alongside CPU/mem on the per-bench page
      so a regression's *shape* (queues stacking up vs CPU saturation)
      is visible without re-running.
  Migration plan: add a `MetricSource` behaviour in `Awfy.Xmpp` with
  `DockerStats` + `Prometheus` impls, switch :local to Prometheus once
  parity is verified locally, leave :aws_clt on docker-stats one cycle
  then flip. Keep the `samples_by_bench` shape in `meta.json` so the
  dashboard renderers don't churn.

## OTP coverage limitations

Only **OTP 26+** because MongooseIM's `worker_pool` dep declares
`{minimum_otp_vsn, "26"}`. The dashboard's existing "headline ratio"
(OTP 28 vs 26 vs 20) is unaffected — that line uses the
all-platforms-geomean of the AWFY suite, which keeps full coverage.

The XMPP benchmark adds a second, narrower line on the trend chart
spanning only the recent half of the OTP range. Honest framing: this
is the "real-app on modern OTP" signal, not the "BEAM evolution over
a decade" signal.

## Failure modes & mitigations

| Failure | Mitigation |
|---|---|
| OTP master breaks MongooseIM build | Small compat patch under `patches/mongooseim-<pin>/`. Master leg is missing until landed; dashboard surfaces the pin-broken state as an annotation. |
| MongooseIM pin upgrade introduces step change | Pin-refresh PR documents the scenario(s) affected, dashboard surfaces the pin change as a chart annotation. Keep old pin running for one ref cycle if the change is large. |
| Port 5222 conflict on `:local` host | `bin/build-mongoose.sh` writes a randomised port into `releases/<vsn>/sys.config`; runner reads it back. |
| Broker doesn't reach READY in 30 s | Treat as a per-run failure — re-run pattern matches existing `measure-windows-target` re-run flow. |
| One MongooseIM cluster node fails to join | Topology orchestrator fails the deploy step; the measure step never runs. No partial-cluster data on the dashboard. |
| RDS connection limit hit during scenario warmup | RDS instance-type pin in the topology config sized for the connection count; reviewed on every scenario change. |
| AWS Terraform apply flakes | Retry up to 3 times in the orchestrator workflow; treat persistent failure as a per-ref skip (`measure-windows-target`-shape recovery). |
| Benchmark machine has TLS hardware acceleration variance | Same caveat as `NETWORK_BENCH_PLAN_TIER1.md`'s TLS family — pin EC2 instance type, document c_compiler / crypto provider in the snapshot specs card. |
| GHA shared-tenancy noise on the network stack | Hard requirement on `runner_pool=aws`; GHA path skipped at workflow level. |

## Open questions

* **Steady-state window length**: ramp at 5 ms × 100k users is
  ~8.3 min, then we need a stable measurement window after. ESL's
  internal CLT runs `dynamic_domains_pm` for a particular duration
  that I don't have a number for — pick 10 min as a starting point
  in Phase 2 and tune based on the per-second sample stream's
  stability after the ramp completes.
* **Topology persistence**: should the AWS `aws_clt` topology be
  spun up per-sweep (~5-10 min Terraform apply, predictable cost) or
  long-running with reset-between-sweeps? With the 8.3-min ramp the
  apply time is no longer dominant — long-running might still win if
  the broker's *warm cache* takes longer than the ramp to stabilise.
  Default to per-sweep; revisit if cache-warm time dominates.
* **Reusing ESL's CLT infrastructure**: if the existing internal
  scaffolding can be repointed at a published-results dashboard
  (the dead `tide.erlang-solutions.com` from a previous era), we
  skip most of Phase 2's Terraform work. Worth a conversation with
  the ESL CLT owners before greenfielding the AWS pieces.
* **Local-topology realism**: 1k users / 10 domains is a 100×
  scale-down. It exercises the *same code paths* as the AWS shape
  but not under the same contention. Numbers from `:local` are
  useful as "did the orchestration work?" not "did this OTP change
  things?". Worth flagging on the dev-namespace dashboard so a
  future reader doesn't conflate the two scales.

## Leave the door open to network-plan reuse

This plan and the network-bench plan have the same overall shape —
deploy a topology, run a scenario, capture throughput + percentiles
over a time window, tear down. The implementations of *each piece*
differ enough (Docker compose vs `ip netns`; Amoc container vs
in-BEAM Benchee) that we are NOT trying to extract a shared
framework now — that's premature abstraction across two specs that
will both evolve. The goal is weaker: **don't lock anything in this
plan's Phase 1 that would make later reuse hard.**

Concrete things Phase 1 will avoid:

* Naming generic-shape modules with XMPP-specific terms. The
  topology behaviour (if there is one) is named `Awfy.AppBench.*`
  / `Awfy.Topology`, not `Awfy.Xmpp.Topology`. XMPP-specific bits
  live under an XMPP-namespaced module.
* Hard-coding XMPP-specific fields into shared schemas. The
  throughput-over-time → `.benchee` mapping helper takes generic
  inputs (samples, scenario name, metadata map) — no
  `:messages_per_user` etc.
* Burying `bin/ensure-docker.sh` under an XMPP-specific path.
  The Colima helper goes at the top level `bin/` from day one.
* Coupling the mix task surface to XMPP. We add
  `mix awfy.measure_xmpp` as a sibling to the planned
  `mix awfy.measure_network`, not a single `awfy.measure --kind`
  flag that pretends they're the same dispatch.

What actually gets factored into shared code (if anything) is a
follow-up decision the network plan can make when it lands. The
factoring is cheap then because Phase 1 leaves clean seams.

## Cross-references

* `EXTENDED_BENCH_PLAN.md` — companion non-network OTP benchmarks
  (BIF / map / phash2 / Mnesia / estone). Lower-tier, higher-coverage
  counterpart to this plan.
* `NETWORK_BENCH_PLAN_TIER1.md` — single-host distribution + TLS.
  Different topology implementation, same shared infrastructure
  layer (see above).
* `TARGET_ELIXIR_RUNNER_PLAN.md` — pinning model + per-ref bundle
  build pattern this plan extends with MongooseIM.
