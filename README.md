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

All 14 benchmarks ported in both languages, plus SOM Vector infrastructure.

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
| Json        | ✅     | ✅     | self-contained parser, 25 KB embedded test string |
| DeltaBlue   | ✅     | ✅     | constraint solver (chain_test + projection_test) |
| Havlak      | ✅     | ✅     | union-find loop recognizer; bit-exact at iter 1/15/150/1500/15000 |
| CD          | ✅     | ✅     | custom Red-Black tree, voxel collision detection |
| **SOM Vector** | ✅ | ✅     | infrastructure for the polymorphic-heavy benchmarks |

## Cross-language numbers (Apple M5, Erlang 28.4.1 + Elixir 1.19.5, Ruby 3.3.0, no YJIT)

Single-shot times via `inner_benchmark_loop(N)` with `N` from `upstream/rebench.conf`. Lower is better.

| Benchmark   | Iter   | Erlang ms | Elixir ms | Ruby ms | Erlang vs Ruby |
|-------------|-------:|----------:|----------:|--------:|---------------:|
| Bounce      |  1500  |    85     |    89     |   542   | **6.4× faster** |
| List        |  1500  |    35     |    91     |   653   | **18.7× faster** |
| Mandelbrot  |   500  |   160     |   163     |   597   | 3.7× faster |
| NBody       | 250000 |   270     |   344     |   888   | 3.3× faster |
| Permute     |  1000  |   145     |   153     |   708   | 4.9× faster |
| Queens      |  1000  |    90     |   130     |   599   | 6.7× faster |
| Sieve       |  3000  |  1999     |  1369     |   952   | **0.48× (slower)** |
| Storage     |  1000  |   199     |    73     |   554   | 2.8× faster |
| Towers      |   600  |    63     |    55     |   668   | **10.6× faster** |
| Richards    |   100  |   491     |  1122     |  1743   | 3.5× faster |
| Json        |   100  |    46     |    73     |   466   | **10.1× faster** |
| CD          |   250  |   464     |   516     |  1127   | 2.4× faster |
| DeltaBlue   | 12000  |  1489     |  1442     |   208   | **0.14× (much slower)** |
| Havlak      |  1500  |   641     |   647     |  1177   | 1.8× faster |

Geomean across all 14: Erlang ~3.0× faster than Ruby, Elixir ~2.7× faster.

### What the numbers say

**Where the BEAM JIT shines (>5× over Ruby)**: List, Towers, Json, Bounce, Queens — code that's loop-heavy, allocates record/tuple values, and benefits cleanly from the JIT specialising on shape.

**Where Ruby beats us (Sieve, DeltaBlue)**:
- **Sieve** is `:array` ops on a 5000-element flag table. The Ruby's mutable `Array#[i]=` is a single store instruction; our persistent `:array` rewrites a HAMT path log-N times per write. Tried switching to a flat 5000-tuple expecting BEAM's destructive-update optimization — it didn't fire across the recursion, ran 25× slower (see `awfy_sieve.erl`). Likely needs `:atomics` or `:counters` to close the gap, but that breaks the persistent-semantics rule. Documented in PROGRESS.md.
- **DeltaBlue** is the worst result: 7× behind Ruby. Mutation-heavy graph: a Variable holds a constraint list, constraints reference variables, the planner mutates current_mark. The port carries everything in `world` maps keyed by id — every "object access" becomes a `maps:get` and every "field write" a `maps:put`. Ruby's MRI does these as direct pointer writes. The structural overhead is the price of immutability; closing the gap needs either tuple-of-records with destructive `setelement` (try and verify the JIT optimization actually fires this time) or a process-dictionary approach (rule-breaking).

### Erlang vs Elixir

| Benchmark   | Erlang | Elixir | Elixir vs Erlang |
|-------------|-------:|-------:|-----------------:|
| List        |    35  |    91  | **2.6× slower** |
| Richards    |   491  |  1122  | **2.3× slower** |
| Storage     |   199  |    73  | **2.7× faster (!)** |
| NBody       |   270  |   344  | 1.3× slower |
| Sieve       |  1999  |  1369  | 1.5× faster |
| (others)    |        |        | within ~10% |

**List (2.6×)** and **Richards (2.3×)**: heavy record/struct field access in tight inner loops. Erlang records compile to tuples with positional `element/2` reads (one-instruction); Elixir structs are atom-keyed maps with hash-and-lookup. Gap is the cost of map vs tuple field read on the hot path.

**Storage (Elixir wins, 2.7×)**: builds throwaway depth-7 trees of nil-filled tuples. Elixir's `Tuple.duplicate(nil, size)` may take a faster allocator path than Erlang's `erlang:make_tuple` for this exact shape — needs more investigation.

## Optimization pass — Phase 2 findings

After Phase 1 (correctness), one pass over the 14 benchmarks for idiomatic-but-not-rule-breaking improvements. Highlights:

- **DeltaBlue chain_test** had `lists:nth(I+1, Vars)` per iteration (O(N²) over 12000 vars). Replaced with pairwise pattern match `[V1, V2 | Rest]` on the chain — O(N). 1864 → 1431 ms (~23% faster).
- **CD `is_in_voxel`**: Ruby relies on IEEE 754 ±Infinity when motion has zero Δx; Erlang's `/` crashes on /0 and substituting 0.0 made the predicate vacuously true, exploding the recursion (8 sec for inner=2 vs 1 ms after fix).
- **Sieve tuple-store** experiment (see above) — kept `:array`.

Open items for the next pass (PROGRESS.md):

- Use `erlc` flags to detect when destructive tuple/binary update optimizations fire in hot paths (`setelement_inplace`, writable binary). For the id-keyed maps in DeltaBlue / Havlak / CD, restructuring as a tuple-of-records with `setelement` could be a big win — *if* the JIT optimization actually applies. The Sieve attempt suggests it doesn't always fire across function calls; need to verify with compiler diagnostics rather than guessing.
- Json's `:binary.at/2` index access could be replaced with binary pattern matching (the canonical Erlang idiom) to enable the writable-binary optimization on the capture buffer.
- Tail-call audit on the slowest benchmarks (Havlak, DeltaBlue): every recursive function should be in tail position; non-TC recursion adds heap growth.
