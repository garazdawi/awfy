# Benchmarks — Requirements

AWFY measures three benchmark suites. Each has a different
purpose, different runtime contract, and different stability
properties. This file says what each suite must guarantee.

See also: [Measurement](measurement.md), [Dashboard](dashboard.md).

## Suites

| Suite             | Lives in                  | Purpose                                    |
| ----------------- | ------------------------- | ------------------------------------------ |
| AWFY synthetic    | `apps/awfy/`              | Cross-language compute (Erlang vs Elixir). |
| OtpBenchmarks     | `apps/otp_benchmarks/`    | BEAM-internal micro/meso-benchmarks.       |
| XMPP application  | `apps/awfy_xmpp/`         | MongooseIM + Amoc application-level load.  |

Each suite is its own mix app under `apps/`, with its own
licensing boundary (AWFY synthetic is MIT, OtpBenchmarks is
Apache-2.0 per OTP source, XMPP is mixed). Suites compile
independently — the runner project depends on each by `path:` so
an old Elixir can compile an old suite without bringing in the
host orchestrator's modern deps.

## AWFY synthetic

Source: Stefan Marr's upstream AWFY (Are We Fast Yet) compute
microbenchmarks. **15 benchmarks** today:

    Bounce, CD, DeltaBlue, Havlak, Json, List, Mandelbrot, NBody,
    Permute, Queens, Richards, Sieve, Storage, Towers,
    Json (and possibly per-bench variants under the same family)

Each benchmark shall:

- Be implemented in **both** Erlang and Elixir variants. The
  dashboard surfaces lang as a series distinction.
- Have a `verify_result/1` that confirms the inner iteration's
  output is deterministic. The verify pass runs once per scenario
  before timing.
- Have a single fixed `inner_iter` count baked into the source.
  Different OTP versions cannot tune the workload — that's the
  cross-version comparability contract.
- Take ~100 ms-1 s per iteration on modern hardware so warmup +
  timing both have headroom.

`mix awfy.measure` shall:

1. Run a **verify pass**: one inner-loop call per scenario, all
   benchmarks. Any scenario whose `verify_result/1` fails is
   marked broken and excluded from the timing pass — but the run
   succeeds with whatever passed.
2. Run a **timing pass** with Benchee under the configured time +
   warmup (default 5 s warmup, 30 s measure per scenario).
3. Skip the timing pass for any scenario broken in verify.

A scenario failing verify shall be visibly reported (not silently
dropped) — verify failures usually mean a regression in the
runtime, not a benchmark bug.

## OtpBenchmarks

Source: ports of OTP test/benchmark code (estone_SUITE.erl etc.).
**~9 families** today:

    base64, binary_match, estone, ets, iolist_size, maps,
    mnesia_tpcb, phash2, unicode

Each family shall:

- Expose a `name/0` returning the canonical identifier (used as
  the `.benchee` filename and the dashboard's grouping key).
- Expose `inputs/0` returning a list of named input shapes the
  family runs against (e.g. `phash2` has 13 inputs covering
  atoms, binaries of varying sizes, tuples, …).
- Expose a per-input runner that Benchee can drive in the same
  shape as AWFY synthetic.

The dashboard shall fold per-input cells into one family-level
geomean before contributing to the suite-wide geomean (see
[Dashboard](dashboard.md) for why).

Families can declare metric variants (CPU time, throughput, etc.)
via the `applications` block in `meta.json`. Default is throughput.

## XMPP application benchmark

Source: MongooseIM + Amoc + `awfy_xmpp` orchestrator. Currently
**one scenario**:

    dynamic_domains_pm

The scenario shall:

- Boot 3 MongooseIM brokers in a Docker Compose stack with CETS
  clustering (`awfy_xmpp/priv/Dockerfile.mongoose`).
- Drive load via Amoc against the broker cluster.
- Sample throughput, CPU usage (host stats), and memory usage per
  broker container at ~1 Hz for the measurement window
  (configurable, default 60 s).
- Write three derived cells to the `.benchee`:
  `xmpp_speed/erlang` (period-ns, lower=faster, inverted for
  display), `xmpp_cpu/erlang`, `xmpp_mem/erlang`.
- Declare the family in `meta.json` under `applications`:
  `[{name: "xmpp", metrics: ["cpu", "mem", "speed"]}]`.

A scenario shall be platform-gated: linux-only, OTP-27+ (see
[Platforms](platforms.md)).

XMPP is the only suite where runtime infrastructure outside the
host can fail (Docker, hex registry, upstream rebar3, etc.). The
runner shall retry compose-up up to 3 times with backoff (10 s,
30 s) before declaring `{:compose_up_failed, _, _}`.

## Cross-suite contract

Adding a new suite shall not require dashboard changes provided
the suite:

- Lives at `apps/<name>/`.
- Adds itself as a path dep in the top-level `mix.exs`.
- Provides `--dry-run` mode on its measure task printing canonical
  benchmark identifiers, one per line, no banners.
- Writes to a `<name>.benchee` file per benchmark / family in the
  run-dir.
- Declares its families in `meta.json`'s `applications` block
  (or registers via `Awfy.benchmarks/0` for the synthetic shape).

## Cross-version comparability

The same benchmark on different OTP versions must measure the same
thing. The pipeline shall guarantee this by:

- Pinning the benchmark source per AWFY release — version-bumping
  `apps/awfy/` or `apps/otp_benchmarks/` requires re-measuring all
  historical SHAs that the bump would affect (typically: not
  routine, treated as an `otp_refs=all` operation).
- Using identical Benchee config across runs (`memory_time: 0`,
  fixed warmup + measure, no per-platform tuning).
- Not letting the runner choose iteration counts dynamically — the
  benchmark source controls workload size.

Any change that would invalidate cross-version comparability shall
be called out in the commit message and accompanied by a re-run of
the affected baseline rows.

## What benchmarks must not do

- Must not allocate unbounded memory in inner loops (skews the GC
  cost across OTP versions disproportionately).
- Must not depend on wall-clock time within the inner loop
  (`os:cmd/1`, file I/O, network) — those are external-state
  dependencies that destroy reproducibility.
- Must not require build-time configuration that varies per OTP
  (defeats the cross-version contract).
