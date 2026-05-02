# Network Bench Plan — Tier 1 (single-host, namespaces)

Companion to `CLOUD_BENCH_PLAN.md`. Adds a *network* axis to the
benchmark sweep: track regressions in distribution, TLS, HTTP, and
port I/O alongside the compute-only AWFY suite. This plan covers
**Tier 1 only** — a single Linux host, two BEAMs, communicating over
loopback or a `veth` pair in a network namespace with simulated
latency. Tier 2 (two-host same-AZ) and Tier 3 (bare-metal pair) are
deferred until Tier 1 is producing useful data.

## Why single-host first

Two-host benchmarks add real NIC + cloud-network noise on top of all
the BEAM-internal sources of variance. Until we have a clean signal
on the *Erlang* side (BIF dispatch, scheduler, allocator, message
system, TLS handshake CPU cost), measuring the cloud network just
muddies the picture. Single-host topologies eliminate the network
silicon entirely and isolate the BEAM-internal pieces — which is
exactly the regression signal we care about for OTP commits.

## Topologies

Three, run as a `topology` matrix axis:

| Tag | Setup | Latency | What it stresses |
|-----|-------|---------|------------------|
| `loopback` | `127.0.0.1`, no namespace | ~10 μs RTT | TCP stack, BIF dispatch, message system. Fastest path. |
| `netns-1ms` | `veth` pair across `ip netns` + `tc qdisc netem delay 500us` per direction | ~1 ms RTT | TCP stack under realistic LAN-like RTT — exposes pipelining, congestion behaviour. |
| `netns-10ms` | same, `tc … delay 5ms` | ~10 ms RTT | WAN-like — exposes any code that scales poorly with RTT (e.g. handshake round-trips). |

Linux only for v1 — `ip netns` doesn't exist on macOS / Windows. The
matrix gates non-Linux jobs out, so the existing macOS / Windows
compute sweeps continue unchanged. (Loopback could in principle run
everywhere, but cross-platform network results compare poorly because
each OS's TCP stack behaves differently — better to keep the network
axis Linux-only and run consistent numbers there.)

## What to port (in priority order)

Sourced from the OTP benchmark inventory; effort is wall-clock for
one experienced engineer.

| # | Source suite | Benchmark | Topology applicability | Effort |
|---|--------------|-----------|------------------------|--------|
| 1 | `distribution_SUITE` | `local_send` (msgs/sec at 1B / 1KB / 1MB payloads) | loopback only (within one node) | low — wraps existing `pong/0` loop |
| 2 | (custom) | `gen_tcp` echo round-trip — open socket, send N, recv N, measure RTT | all three | low — ~50 LoC |
| 3 | `distribution_SUITE` | `bulk_send` between two BEAM nodes | all three (two BEAMs in two namespaces) | medium — need to wire `epmd` + cookies inside namespaces |
| 4 | `distribution_SUITE` | `message_latency` — link/monitor exits, exit2 signals | all three | medium |
| 5 | `ssl_bench_SUITE` | `setup` group — TLS handshakes/sec | all three | medium — port suite to use Benchee, drop the multi-machine plumbing |
| 6 | `httpd_bench_SUITE` | Inets `httpd` GET req/sec, small + big payloads | all three | medium — keep server in-process, drop nginx variant |
| 7 | `stdlib_bench_SUITE` | `gen_server`, `gen_statem` call latency | loopback only (intra-node) | low — already in-process |

Tier 1 ships with **all seven**. They cover the four core network
subsystems (raw TCP, distribution, TLS, HTTP) plus the OTP behaviour
overhead that effectively *is* network-shaped from the application's
view (gen_server is IPC).

## Code structure

```
lib/awfy/network/
├── topology.ex                # set up / tear down loopback + netns
├── benchmark.ex               # behaviour: setup/2, run/2, teardown/2
└── benchmarks/
    ├── tcp_echo.ex            # raw gen_tcp round-trip
    ├── distribution_send.ex   # distribution_SUITE.local_send port
    ├── distribution_bulk.ex   # distribution_SUITE.bulk_send port
    ├── tls_setup.ex           # ssl_bench_SUITE.setup port
    ├── http_inets.ex          # httpd_bench_SUITE port (Inets)
    └── gen_server_call.ex     # stdlib_bench_SUITE gen_server call port

bin/
└── setup-netns.sh             # Linux: veth + ip netns + tc qdisc netem

lib/mix/tasks/
└── awfy.measure_network.ex    # entry point — sets topology, runs benchmarks
```

`Awfy.Network.Benchmark` mirrors the existing `Awfy.Benchmark`
behaviour but adds `setup/2` (returns context) and `teardown/2`. The
context is whatever the benchmark needs: socket pairs, BEAM node refs,
HTTP server pid, etc. Benchee's `:before_each` / `:after_each` hooks
run setup/teardown around the timed loop.

## Mix task

```
mix awfy.measure_network                          # all topologies, all bench
mix awfy.measure_network --topology loopback      # just loopback
mix awfy.measure_network --benchmarks tcp_echo,tls_setup
```

Reuses the same `results/<run-dir>/` save shape as `mix awfy.measure`
so `mix awfy.compare` already produces the dashboard. The run-dir
label gets a `-net-<topology>` suffix so multiple topologies don't
collide.

## CI integration

Add a single job to `.github/workflows/bench.yml`:

```yaml
measure-network-linux:
  needs: [resolve, build-linux]
  strategy:
    fail-fast: false
    matrix:
      topology: [loopback, netns-1ms, netns-10ms]
      flavor: [jit, emu]
  runs-on:
    - codebuild-awfy-bench-linux-x86_64-${{ … }}
  steps:
    - uses: actions/checkout@v4
    - run: docker pull ghcr.io/${{ github.repository }}:${{ … }}-x86_64
    - if: startsWith(matrix.topology, 'netns-')
      run: sudo ./bin/setup-netns.sh ${{ matrix.topology }}
    - run: |
        docker run --rm --network=host --cap-add=NET_ADMIN \
          -e ERL_FLAGS="${{ matrix.flavor == 'emu' && '-emu_flavor emu' || '' }}" \
          -v "$PWD/results:/app/results" \
          ghcr.io/${{ github.repository }}:${{ … }}-x86_64 \
          awfy.measure_network \
            --topology ${{ matrix.topology }} \
            --label ${{ … }}-net-${{ matrix.topology }}-${{ matrix.flavor }} \
            --ignore-preflight
```

Six new jobs (3 topologies × 2 flavors), each ~10 min, all on the
existing Linux x86 CodeBuild project. No new AWS resources. Cost:
~$0.30 / sweep added, $110/yr daily. Same artifact + publish flow as
the compute jobs; the `mix awfy.compare` dashboard picks them up
automatically.

ARM and Windows are excluded from the network axis in v1: ARM
because it's lower-priority for network-stack work (the BEAM TCP
path doesn't differ meaningfully by arch), Windows because `ip
netns` doesn't exist. Add ARM later if data shows it diverging.

## Noise control

`mix awfy.preflight` already covers system-level noise. Network
benchmarks add a few specific concerns:

- **`tc qdisc netem` jitter** — netem with constant delay is
  deterministic, but if any other process touches the same interface
  the qdisc behaves nondeterministically. Pin namespaces to a
  dedicated `veth` pair, never to `lo` or the host's primary NIC.
- **TCP timestamps** — kernel default-on; we leave them on (matches
  production reality), but flag in metadata so cross-run comparison
  is apples-to-apples.
- **Ephemeral port range** — high-throughput tests can exhaust it.
  Set `net.ipv4.ip_local_port_range = 10000 65535` at job start.
- **Don't run multiple network bench jobs concurrently on the same
  CodeBuild instance.** Concurrency: `network-${{ runner }}` group on
  this single job to serialise.

## Open questions

1. **Sample counts for latency tests.** Compute benchmarks at 4-10s
   per scenario gives 50-100 samples. A TLS handshake takes ~1ms, so
   the same window gives ~10k samples — overkill. Calibrate per
   benchmark like we did for the compute side; lock numbers after
   first stable run.

2. **`Inets` vs `Cowboy` for HTTP throughput.** `httpd_bench_SUITE`
   uses Inets, which is what ships with OTP. But many production
   users run Cowboy — and a regression in Cowboy's hot path on a new
   OTP doesn't surface in an Inets benchmark. Out of scope for v1
   (stick with Inets for source-of-truth coverage), but worth a note.

3. **Should TLS use ChaCha20 or AES?** Cipher choice swings handshake
   numbers by 5-10×. Run both as separate benchmarks rather than
   picking one — same pattern as ports/lang in the AWFY suite.

4. ~~**Distribution cookie + `epmd` inside the netns.**~~ Resolved
   by `ISOLATION_POLICY.md` — each network benchmark runs in its
   own fresh peer pair (inside the pre-set-up netns), and epmd
   state never crosses a benchmark boundary. The setup script just
   has to provision the namespaces; per-benchmark peer lifecycle
   handles the rest.

5. **Comparison semantics across topologies.** `tcp_echo` on
   loopback vs `netns-10ms` aren't comparable as throughput numbers
   (they measure different things — RTT-bound vs CPU-bound). The
   dashboard should show topologies as separate series, not a
   "ratio" view. Existing `mix awfy.compare` already filters by
   label; add a topology-aware grouping in the UI when it gets
   noisy.

## Sequence

1. Spike: write `bin/setup-netns.sh` and confirm `tc qdisc netem
   delay` produces stable RTTs locally (< 5% jitter) on a Linux box.
2. `Awfy.Network.Benchmark` behaviour + `Awfy.Network.Topology` module.
3. Port `tcp_echo` first — simplest end-to-end benchmark, validates
   the whole pipeline.
4. Add `mix awfy.measure_network` task; verify save/load/compare
   integration with the existing dashboard.
5. Port `distribution_send`, then `gen_server_call` (both intra-node,
   low risk).
6. Port `distribution_bulk` (cross-namespace, harder).
7. Port `tls_setup` and `http_inets`.
8. Wire the GHA job; first run will burn through cache misses — let
   it stabilise over 3-4 daily sweeps before judging numbers.
9. Calibrate per-benchmark `:time` for stability, similar to the
   compute calibration pass we did before.

## Why not …

- **Run all topologies in one Mix task invocation** — keeping them
  as separate jobs gives independent caching, parallelism on the CI
  side, and isolates failures (a `netns-10ms` setup bug doesn't
  block the loopback numbers).
- **Use Docker's built-in network drivers** instead of `ip netns` —
  Docker bridges add their own iptables / NAT overhead that's hard
  to reason about. Raw `veth` + `netem` is the most predictable
  recipe for "exactly N ms of latency with zero NAT."
- **Run on macOS / Windows** — Tier 1's value is reproducibility, not
  cross-platform coverage. Adding `pf`-based latency simulation on
  macOS or `netsh interface tcp` quirks on Windows would multiply the
  failure modes without much extra signal.
