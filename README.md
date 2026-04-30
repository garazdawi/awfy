# Are We Fast Yet — Erlang + Elixir Port

Mix project porting [Are We Fast Yet (AWFY)](https://github.com/smarr/are-we-fast-yet) to **both Erlang and Elixir**. AWFY is the de-facto cross-language JIT comparison suite — 14 benchmarks already ported to 11 languages. Adding BEAM ports lets us measure JIT progress against V8, YJIT, LuaJIT, JVM, and others on the same code.

- **Detailed plan**: [`PORT_PLAN.md`](PORT_PLAN.md)
- **Motivation**: [`../IDEAS/32-jit-benchmarks.md`](../IDEAS/32-jit-benchmarks.md)
- **Upstream reference**: [`upstream/`](upstream/) (git submodule of `smarr/are-we-fast-yet`)

## Layout

```
awfy/
├── upstream/                       # AWFY source (submodule, reference only)
├── PORT_PLAN.md                    # detailed port plan
├── .tool-versions                  # asdf: erlang 28.4.1, elixir 1.19.5, ruby 3.3.0
├── mix.exs                         # single Mix project for both ports
├── lib/                            # Elixir benchmarks
│   ├── awfy.ex                     # public API
│   └── awfy/
│       ├── benchmark.ex            # Elixir behaviour
│       ├── random.ex               # SOM-compatible LCG
│       └── benchmarks/
│           └── bounce.ex
├── src/                            # Erlang benchmarks (compiled by mix)
│   ├── awfy_benchmark.erl          # Erlang behaviour
│   ├── awfy_random.erl
│   └── awfy_bounce.erl
└── test/
    ├── test_helper.exs
    ├── benchmarks_test.exs         # one ExUnit test per registered benchmark
    └── random_test.exs             # Random ports match Ruby reference
```

## Running the tests

```
$ mix test
....
Finished in 0.00 seconds (0.00s async, 0.00s sync)
4 tests, 0 failures
```

Each registered benchmark gets one test that runs `inner_benchmark_loop(1)` and asserts the result is correct. As we port more benchmarks, each new one adds two tests (Erlang + Elixir).

## Benchmarking with Benchee

The `mix awfy.benchee` task runs benchmarks under [Benchee](https://hexdocs.pm/benchee), which gives us an interactive Erlang-vs-Elixir comparison alongside ips/median/deviation.

```
$ mix awfy.benchee Bounce
=== Bounce (inner_iter=1500) ===

Name                    ips        average  deviation         median         99th %
Bounce/erlang          8.70      114.90 ms     ±1.17%      115.33 ms      116.33 ms
Bounce/elixir          8.36      119.68 ms     ±5.12%      122.99 ms      125.07 ms

Comparison:
Bounce/erlang          8.70
Bounce/elixir          8.36 - 1.04x slower +4.78 ms
```

Default `inner_iter` per benchmark mirrors `upstream/rebench.conf`. Common flags:

```
mix awfy.benchee                       # all benchmarks, both languages
mix awfy.benchee Bounce                # one benchmark, both languages
mix awfy.benchee --lang erlang         # all benchmarks, Erlang only
mix awfy.benchee Bounce --inner-iter 100
mix awfy.benchee Bounce --time 1 --warmup 0   # quicker iteration
```

This is the BEAM-native way to iterate on JIT changes — flip `+JMsingle false` (or whichever flag turns T2 on/off when ready) and rerun. For the canonical AWFY-format numbers (matching the upstream `harness.rb` output), use the AWFY-style runner that lands in Phase 5.

## Running the Ruby reference

From `upstream/benchmarks/Ruby/`:

```
ruby harness.rb Bounce     1 100
ruby harness.rb DeltaBlue  1 100
ruby harness.rb Richards   1 5
```

The `inner_iterations` count amortizes startup; AWFY's `rebench.conf` specifies appropriate defaults per benchmark.

## Status

Phase 0 (skeleton + test harness) and Phase 1 (Bounce smoke test) from `PORT_PLAN.md` are done. Both Erlang and Elixir Bounce produce the expected result of 1331 bounces.

| Benchmark   | Erlang | Elixir |
|-------------|--------|--------|
| Bounce      | ✅     | ✅     |
| List        | —      | —      |
| Mandelbrot  | —      | —      |
| NBody       | —      | —      |
| Permute     | —      | —      |
| Queens      | —      | —      |
| Sieve       | —      | —      |
| Storage     | —      | —      |
| Towers      | —      | —      |
| DeltaBlue   | —      | —      |
| Richards    | —      | —      |
| Json        | —      | —      |
| Havlak      | —      | —      |
| CD          | —      | —      |
