<!--
SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
SPDX-License-Identifier: Apache-2.0
-->

# AWFY Port Plan: Erlang + Elixir

This document is the detailed plan for porting [Are We Fast Yet (AWFY)](https://github.com/smarr/are-we-fast-yet) to Erlang and Elixir. Quick context lives in [`../README.md`](../README.md); the wider motivation lives in [`../../IDEAS/32-jit-benchmarks.md`](../../IDEAS/32-jit-benchmarks.md).

## Goals

1. **Cross-language JIT comparison.** Produce numbers that can sit alongside the existing AWFY datasets for V8, YJIT, LuaJIT, JVM, etc.
2. **Erlang-vs-Elixir comparison.** Two ports of every benchmark, written in matching styles, so we can isolate Elixir compiler overhead from BEAM JIT effects.
3. **JIT regression tracking.** Run on T1 (current BeamAsm) and T2 (when ready) so we can attribute speedups to specific JIT passes.

## Layout (single Mix project)

This folder *is* the Mix project. Erlang sources and Elixir sources live side by side in the same app.

```
awfy/
├── upstream/                     # AWFY git submodule (reference)
├── README.md                     # high-level orientation
├── PORT_PLAN.md                  # this file
├── .tool-versions                # asdf: Ruby 3.3.0, Elixir 1.19.5, Erlang 28.4.1
├── mix.exs                       # Mix project file
├── .formatter.exs                # Elixir formatter config
├── lib/                          # Elixir code (mix's default lib path)
│   ├── awfy.ex                   # public API (delegates to runner)
│   ├── awfy/
│   │   ├── benchmark.ex          # Elixir behaviour
│   │   ├── runner.ex             # harness + measurement
│   │   ├── som.ex                # SOM utility classes (Vector, Set, Dict, Random)
│   │   └── benchmarks/
│   │       ├── bounce.ex
│   │       ├── permute.ex
│   │       ├── ...
│   │       └── (14 benchmarks)
├── src/                          # Erlang code (mix compiles this with erlc)
│   ├── awfy_benchmark.erl        # Erlang behaviour
│   ├── awfy_runner.erl           # Erlang harness (parallel to Elixir runner)
│   ├── awfy_som.erl              # SOM utility module
│   ├── awfy_bounce.erl
│   ├── awfy_permute.erl
│   ├── ...
│   └── (14 benchmarks)
├── include/
│   └── awfy.hrl                  # Shared records (e.g. som vector record)
└── test/
    ├── test_helper.exs
    ├── elixir_benchmarks_test.exs   # asserts every Elixir bench passes verify_result
    ├── erlang_benchmarks_test.exs   # asserts every Erlang bench passes verify_result
    └── som_test.exs                 # property tests on the SOM utilities
```

### Why one Mix project, not two

Mix natively compiles `.erl` files in `src/` alongside `.ex` files in `lib/`. Single project gives us:

- One test runner (ExUnit) that asserts both Erlang and Elixir benchmarks pass.
- One harness binary (`mix awfy.run`) that can run any benchmark in either language.
- No duplication of dependency/tooling config.
- Symmetry that exposes Elixir-vs-Erlang differences clearly.

## Core abstractions

### Erlang behaviour (`src/awfy_benchmark.erl`)

```erlang
-module(awfy_benchmark).
-export_type([result/0]).
-export([default_loop/2]).

-type result() :: term().

-callback inner_benchmark_loop(InnerIter :: non_neg_integer()) -> boolean().
-callback name() -> string().

%% Helper for benchmarks whose verify_result/1 doesn't depend on InnerIter.
%% Equivalent to Ruby's default Benchmark#inner_benchmark_loop.
default_loop(_Mod, 0) -> true;
default_loop(Mod, N) ->
    case Mod:verify_result(Mod:benchmark()) of
        true  -> default_loop(Mod, N - 1);
        false -> false
    end.
```

Benchmarks where verification depends on `InnerIter` (Mandelbrot, NBody, Havlak) implement `inner_benchmark_loop/1` directly. The simple ones use the default helper.

### Elixir behaviour (`lib/awfy/benchmark.ex`)

```elixir
defmodule Awfy.Benchmark do
  @callback inner_benchmark_loop(inner_iter :: non_neg_integer()) :: boolean()
  @callback name() :: String.t()

  defmacro __using__(_) do
    quote do
      @behaviour Awfy.Benchmark
      def inner_benchmark_loop(0), do: true
      def inner_benchmark_loop(n) do
        if verify_result(benchmark()) do
          inner_benchmark_loop(n - 1)
        else
          false
        end
      end
      defoverridable inner_benchmark_loop: 1
    end
  end
end
```

### Translation rules (Ruby → Erlang/Elixir)

These follow AWFY's `docs/guidelines.md` (idiomatic but disciplined) plus our own functional-language adaptations.

| Ruby idiom | Erlang | Elixir |
|------------|--------|--------|
| `class Foo; @x = 1; end` | record `#foo{x = 1}`, threaded through pure funs | `defstruct [:x]`, threaded through pure funs |
| `obj.method(arg)` | `Mod:method(Obj, Arg)` | `Mod.method(obj, arg)` |
| Mutable instance var | New record returned from each call | New struct returned from each call |
| `Array.new(N, init)` | `array:new(N, [{default, Init}])` for large; tuple for small | `:array.new(...)` or `Tuple.duplicate/2` |
| `arr[i] = v` (mutation) | `array:set(I, V, Arr)` returning new array | `:array.set(i, v, arr)` returning new array |
| `each { ... }` | `lists:foreach/2` or recursion | `Enum.each/2` or recursion |
| Polymorphic dispatch | Tag + `case` (preserve dispatch shape!) | Protocol or tag + case |
| `random.next` | Pure-functional LCG, return `{Value, NewSeed}` | Same |

**Critical**: DeltaBlue and Richards specifically test polymorphic call sites. The Erlang/Elixir port must preserve that shape — a "method" on a polymorphic object must compile to a real dispatch (case-on-tag, protocol, or fun call), not be inlined away by the AOT compiler. Otherwise we trivialize the benchmark.

## Phasing

### Phase 0 — Mix project skeleton + test harness (1–2 days)

The user's explicit instruction: **start with the tests so we can run them**. Phase 0 is everything needed to write `mix test` and have it pass on zero benchmarks.

1. `mix.exs` configured for Elixir + Erlang sources.
2. `awfy_benchmark` Erlang behaviour + `Awfy.Benchmark` Elixir behaviour.
3. Empty registry (`Awfy.benchmarks/0` returns `[]`).
4. ExUnit test that iterates the registry, runs `inner_benchmark_loop(1)`, asserts true.
5. `mix test` passes (vacuously — empty list).

**Exit criterion**: `mix test` exits 0.

### Phase 1 — First benchmark + test harness validation (1 day)

Port **Bounce** in both languages as the smoke test for the harness.

1. `src/awfy_bounce.erl` — Erlang port of bounce.rb.
2. `lib/awfy/benchmarks/bounce.ex` — Elixir port.
3. Both register in the runner module-list.
4. ExUnit test runs both, asserts `verify_result/1` returns true.
5. Random has to be ported first (`som.rb`'s deterministic LCG) because Bounce uses it.

**Exit criterion**: `mix test` exits 0 with two benchmarks running, both Erlang and Elixir Bounce produce 1331 bounces.

### Phase 2 — Simple benchmarks (1–2 weeks)

Port the eight smallest benchmarks in both languages. Each has a fixed expected result (no `inner_iterations` dependency, no SOM utilities beyond Random):

- Bounce (done in Phase 1)
- Sieve — expects 669
- Permute — expects 8660
- Towers — expects 8191
- Queens — expects true
- Storage — expects 5461
- Mandelbrot — expects 191 at inner_iter=500 (depends on inner_iter)
- NBody — expects -0.1690859889909308 at inner_iter=250000 (depends on inner_iter)
- List — expects 10

Each port is ~100–200 lines of source. Pace: ~1 benchmark per language per day, two languages, so ~half a week per benchmark pair.

**Exit criterion**: All 9 simple benchmarks pass `mix test` in both languages.

### Phase 3 — SOM utilities + polymorphic benchmarks (2–3 weeks)

DeltaBlue and Richards both depend on the SOM utility classes (`Vector`, `Set`, `Dictionary`, `IdentityDictionary`, `Random`). Port these once; reuse from both languages.

1. **SOM utilities** in Erlang (`src/awfy_som.erl`) + Elixir (`lib/awfy/som.ex`). About 500 LOC each. Property-test them against the Ruby reference using known seeds.
2. **DeltaBlue** — constraint solver. ~700 lines of source per language. The translation has to preserve polymorphic dispatch (each constraint type's `mark`, `is_input`, `output`, etc.).
3. **Richards** — task scheduler simulation. ~440 lines per language. Same dispatch-preservation rule.

**Exit criterion**: DeltaBlue + Richards pass verify_result in both languages.

### Phase 4 — Larger benchmarks (2–3 weeks)

- **Json** — parser + recursive descent. ~530 lines per language. Reuses som's Dictionary.
- **CD** — collision detection, realistic OO. ~840 lines per language.
- **Havlak** — loop recognition. ~500 lines per language. Reuses som's Vector + Set.

**Exit criterion**: All 14 benchmarks pass `mix test` in both languages.

### Phase 5 — Measurement harness + AWFY-compatible output (3–5 days)

1. Time each benchmark's `inner_benchmark_loop` using `erlang:monotonic_time/1` at nanosecond resolution (matching Ruby's `Process.clock_gettime(CLOCK_MONOTONIC, :nanosecond)`).
2. Output in AWFY's RebenchLog format so `rebench` can ingest the numbers without changes:

   ```
   Starting Bounce benchmark ...
   Bounce: iterations=1 runtime: 35584us
   Bounce: iterations=1 average: 35584us total: 35584us

   Total Runtime: 35584us
   ```

3. Add Mix tasks: `mix awfy.run BenchName [iters [inner_iters]]`, `mix awfy.run_all`.
4. Add the executor stanzas to `upstream/rebench.conf` (or our own copy) so `rebench` can drive it.

**Exit criterion**: `mix awfy.run Bounce 10 100` produces output indistinguishable in shape from the Ruby harness.

### Phase 6 — Numbers + writeup (1 week)

1. Run all 14 benchmarks under:
   - Erlang on OTP master + T1 (BeamAsm)
   - Erlang on OTP master + T2 (when available)
   - Elixir 1.19 on the same Erlang versions
   - Reference: Ruby (no YJIT), Ruby (YJIT), JavaScript (V8), Java (HotSpot)
2. Build a comparison table.
3. Compute geometric means per language.
4. Land results in this folder under `results/<date>/`.

**Exit criterion**: A markdown report with all numbers, posted in this folder.

## Random (port first, blocks everything)

The SOM `Random` is a deterministic LCG with seed 74755:

```ruby
class Random
  def initialize; @seed = 74_755; end
  def next; @seed = ((@seed * 1_309) + 13_849) & 65_535; end
end
```

Erlang version (pure-functional, returns `{Value, NewSeed}`):

```erlang
-module(awfy_random).
-export([new/0, next/1]).

new() -> 74755.
next(Seed) ->
    NewSeed = ((Seed * 1309) + 13849) band 65535,
    {NewSeed, NewSeed}.
```

Elixir mirror in `Awfy.Random`. Both ports share the seed across all benchmarks; this is what makes the expected results deterministic across languages.

**Validation**: emit the first 100 values from each port and diff against the Ruby reference. Must match byte-for-byte.

## Open questions for the port

- **Mutable arrays for Storage/Sieve.** Storage allocates `Array.new(size, true)` then sets indices to `false`. The Erlang port can use `array:new` (persistent, log N access) or `tuple` + `setelement` (linear copy). Tuple is closer to Ruby's mutation semantics performance-wise; `:array` is more idiomatic. Probably tuple, with a note that this biases the benchmark toward "copy-on-write tuples are fast" rather than "BEAM has fast arrays".
- **Polymorphism in DeltaBlue.** Several options for translation:
  - **Tag + case dispatch** (most BEAM-natural): `case Constraint of {scale_constraint, ...} -> ...; {edit_constraint, ...} -> ...`. Easy to read but the case dispatch is too direct — the JIT can specialize.
  - **Function pointers in records**: `#constraint{mark = fun scale_mark/1, ...}`. Closer to vtable; harder for the JIT to inline.
  - **Behaviours**: `-behaviour(constraint)` per constraint type, dispatch via `Mod:mark(C)`. Most "polymorphic" in BEAM terms.
  - Decision: try **behaviours** first. They're the closest BEAM analogue of Ruby's method dispatch and what we want to stress in the JIT.
- **Elixir style**. Strict translation rules — preserve algorithm/structure even if it's un-Elixiry. Use `Enum` only where the Ruby uses `each`; use direct recursion where the Ruby uses `times`/`upto`. Don't introduce protocols where Ruby uses class dispatch unless that's the natural BEAM mapping. Goal: make Elixir-Erlang differences come from compiler choices, not idiom choices.
- **Test failure mode.** When a port produces the wrong number, the ExUnit failure should make it clear whether it's the Erlang or Elixir port. Use distinct test module names (`AwfyTest.ErlangBenchmarks` vs `AwfyTest.ElixirBenchmarks`) so the test report is unambiguous.
- **Benchmark registry.** Could be a hand-maintained list or auto-discovered via `:application.get_key/2`. Hand-maintained is simpler and more explicit; auto-discovery risks running modules that aren't benchmarks.

## Effort estimate

Per the IDEAS doc: ~3–5 weeks total. Updated breakdown:

- Phase 0 (skeleton + tests): 1–2 days
- Phase 1 (Bounce): 1 day
- Phase 2 (8 simple benchmarks × 2 langs): 1–2 weeks
- Phase 3 (SOM + DeltaBlue + Richards × 2): 2–3 weeks
- Phase 4 (Json + CD + Havlak × 2): 2–3 weeks
- Phase 5 (measurement harness): 3–5 days
- Phase 6 (numbers + writeup): 1 week

Total: **6–9 weeks** for both Erlang AND Elixir ports of all 14 benchmarks with comparison numbers — slower than IDEAS's original estimate because we're doing both languages, not just one.

If only one language is required, halve Phases 2–4, total ~3–5 weeks.
