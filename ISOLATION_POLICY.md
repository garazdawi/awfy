# Isolation Policy — every benchmark gets a fresh BEAM

**Cross-cuts**: `BENCH_VERSIONS_PLAN.md`, `CLOUD_BENCH_PLAN.md`,
`NETWORK_BENCH_PLAN_TIER1.md`, `EXTENDED_BENCH_PLAN.md`. Supersedes
prior wording in those plans about "run mnesia last", "warm
supervisor tree perturbs subsequent benchmarks", etc.

## Policy

Every individual benchmark runs in a **fresh BEAM peer node**.
No exceptions — including the AWFY compute suite that's currently
in-process.

If a benchmark needs warm caches (JIT tier-up, allocator pools, ETS
table init), that warmup is the **benchmark's own responsibility**,
expressed through Benchee's existing `:warmup` window or via custom
`:before_scenario` setup. We never depend on leftover state from a
previous benchmark in the same VM.

## Why

- **Hermetic results.** Every measurement starts from a known-cold
  state. No order-of-execution effects, no implicit cross-benchmark
  warmup, no "mnesia heartbeat timer is consuming 0.5% of a
  scheduler in the background."
- **Reproducibility under reordering.** Two sweeps that ran the
  same benchmarks in different orders should produce comparable
  numbers. With shared-VM execution, they don't — the second
  benchmark in any pair is always slightly faster.
- **Resolves cross-cutting open questions** in three plans at once:
  - Mnesia leaving its supervisor tree warm (was: "run mnesia
    last")
  - Network benchmarks leaving sockets / TLS sessions / epmd
    state behind (was: "epmd-in-namespace ordering" open question)
  - Crypto NIF first-call overhead bleeding into later runs
  - estone `msgp` leaving links in mailboxes for later micros
- **Forces benchmarks to be honest about their own warmup needs.**
  If a Mnesia ram-copies benchmark needs 5 seconds of warmup
  transactions before timing starts, that gets written explicitly
  into the benchmark's `:before_scenario`. No more pretending the
  whole-suite warmup was free.

## Implementation

A new `Awfy.PeerRunner` module wraps each benchmark invocation:

```elixir
def run_benchmark(name, scenarios, benchee_opts) do
  {:ok, pid, node} =
    :peer.start_link(%{
      name: peer_name(name),
      args: ['-pa' | code_paths()],
      connection: :standard_io
    })

  try do
    :erpc.call(node, fn ->
      Benchee.run(scenarios, benchee_opts)
    end)
  after
    :peer.stop(pid)
  end
end
```

Key points:
- **One peer per benchmark name**, not per scenario. The Erlang
  port and Elixir port for the same benchmark (e.g. `Bounce/erlang`
  + `Bounce/elixir`) share a peer since they don't mutate global
  state across scenarios. The peer dies between *benchmarks*.
- **Saves go directly to disk from the peer.** Benchee's `save:
  [path:, tag:]` option writes the `.benchee` file from within the
  peer; absolute path on the shared filesystem. Controller doesn't
  need to RPC the result back.
- **Code paths are inherited**, so the peer loads the already-
  compiled `Awfy` + `Benchee` from `_build/`.

## Cost

- **Peer startup**: ~300-500 ms per benchmark.
- **Total added wall clock per sweep**: ~50 benchmarks × 500 ms ≈
  25 s per platform leg, ≈ 3 min per full sweep across the matrix.
- **Cost impact**: trivial. Falls under per-job CodeBuild rounding.
- **Wall clock impact**: also trivial — sweeps are paced by the
  slowest job (Windows with Mnesia at ~15-20 min), not by these
  added seconds.

## Consequences for the existing plans

- **`CLOUD_BENCH_PLAN.md`** — implementation note: the current
  `mix awfy.measure` runs everything in one BEAM. Migrate to peer-
  per-benchmark before the network and extended plans land.
- **`NETWORK_BENCH_PLAN_TIER1.md`** — the open question about
  "epmd cookie + ordering inside the netns" goes away: each
  network benchmark spins up its own pair of peer nodes (in the
  pre-set-up netns), tears them down, and the controller never
  inherits epmd state between benchmarks.
- **`EXTENDED_BENCH_PLAN.md`** — the open question about Mnesia
  perturbing later benchmarks via warm supervisor tree goes away.
  Mnesia can run in any order; its peer is gone by the time the
  next benchmark starts. Drop the "run mnesia last" advice.

## Sequencing

This is a relatively small refactor (estimated 1-2 days):

1. Add `Awfy.PeerRunner` with the `start/run/stop` flow above.
2. Modify `Awfy.BencheeRunner.run_one/3` to delegate to
   `PeerRunner` instead of running Benchee in-process.
3. Confirm the verify-then-time pattern still works inside the peer
   (it should — verify is just one call to `inner_benchmark_loop/1`,
   trivially RPC-able).
4. Spike: re-run the existing AWFY suite with isolation, confirm
   numbers match within ±1% (cold-cache penalty is small for tight
   compute loops where the JIT tiers up in milliseconds).
5. If any benchmark suddenly looks meaningfully slower (>2%) under
   isolation, that's a sign it was depending on warmup that should
   have been explicit — fix at the benchmark, not by relaxing the
   policy.
6. Land before the network or extended plans start adding
   benchmarks; those plans assume isolation from day one.
