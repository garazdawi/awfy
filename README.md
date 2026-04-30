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

10 of 14 benchmarks ported in both languages plus SOM Vector infrastructure.

| Benchmark   | Erlang | Elixir | Notes |
|-------------|--------|--------|-------|
| Bounce      | ✅     | ✅     | 1331 |
| List        | ✅     | ✅     | Custom Element record/struct |
| Mandelbrot  | ✅     | ✅     | InnerIter-dependent verify (1→128, 500→191, 750→50) |
| NBody       | ✅     | ✅     | InnerIter-dependent verify, bit-exact match at 250000 |
| Permute     | ✅     | ✅     | 8660 |
| Queens      | ✅     | ✅     | 8-queens × 10 |
| Richards    | ✅     | ✅     | bit-exact: queue_count=23246, hold_count=9297 |
| Sieve       | ✅     | ✅     | 669 (primes ≤ 5000) |
| Storage     | ✅     | ✅     | 5461 (depth-7 tree) |
| Towers      | ✅     | ✅     | 8191 = 2^13 - 1 |
| **SOM Vector** | ✅ | ✅     | infrastructure for the polymorphic-heavy benchmarks |
| DeltaBlue   | —      | —      | needs SOM IdentityDictionary |
| Json        | —      | —      | self-contained parser, large embedded test string |
| Havlak      | —      | —      | needs SOM Set + IdentitySet + IdentityDictionary |
| CD          | —      | —      | self-contained, custom Red-Black tree |

## Cross-language numbers (Apple M5, Erlang 28.4.1 + Elixir 1.19.5, no T2 yet)

`mix awfy.benchee --time 1 --warmup 0` (production inner_iter from `rebench.conf`):

| Benchmark   | Erlang ips | Elixir ips | Elixir slower by |
|-------------|------------|------------|------------------|
| Bounce      | 8.87       | 8.54       | 1.04x |
| List        | 29.04      | 11.61      | **2.50x** |
| Mandelbrot  | 6.16       | 6.04       | 1.02x |
| NBody       | 3.39       | 2.50       | 1.36x |
| Permute     | 5.95       | 5.92       | 1.00x |
| Queens      | 6.28       | 6.09       | 1.03x |
| Richards    | 1.26       | 0.64       | **1.97x** |
| Sieve       | 0.52       | 0.52       | 1.01x (faster!) |
| Storage     | 4.05       | 6.20       | **0.65x** (Elixir faster) |
| Towers      | 5.26       | 5.10       | 1.03x |

Findings:
- **List (2.50x slower)** and **Richards (1.97x slower)** are the standout Elixir-loses cases. Both are heavy on record/struct field access in tight inner loops — Erlang records compile to tuples with positional access (one-instruction read), while Elixir structs are maps with atom-keyed access (hash-and-lookup). The gap is the cost of map vs tuple read.
- **Storage (1.53x faster in Elixir)** — only benchmark where Elixir wins. The benchmark allocates trees of nil-filled tuples and discards them; Elixir's struct allocator may be doing something cleverer here.
- **Sieve identical**: large `:array` operations dominate; both languages call the same Erlang stdlib, so no language-level difference shows.
- **NBody (1.36x slower)**: float arithmetic in record/struct inner loops, again paying the field-access tax.
