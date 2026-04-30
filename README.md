# Are We Fast Yet — Erlang Port

Workspace for porting [Are We Fast Yet (AWFY)](https://github.com/smarr/are-we-fast-yet)
to Erlang. AWFY is the de-facto cross-language JIT comparison suite — 14
benchmarks already ported to 11 languages (C++, Java, JavaScript, Python,
Ruby, Crystal, Lua, Smalltalk, SOM, SOMns). Adding an Erlang port lets us
measure BEAM JIT progress against V8, YJIT, LuaJIT, JVM, GraalVM, and
others on the same code.

See [`IDEAS/32-jit-benchmarks.md`](../IDEAS/32-jit-benchmarks.md) for
motivation and plan.

## Layout

- `upstream/` — git submodule, the AWFY source. Cloned from
  `https://github.com/smarr/are-we-fast-yet`.
- `.tool-versions` — asdf pin for Ruby 3.3.0, used only inside this folder
  for running the Ruby reference numbers.

## The 14 benchmarks (Ruby source sizes)

| Benchmark | LOC | Stresses |
|-----------|-----|----------|
| Bounce | 89 | Basic OO, allocation |
| List | 88 | Linked-list traversal, recursion |
| Mandelbrot | 117 | Tight float arithmetic |
| NBody | 179 | Float arithmetic, array access |
| Permute | 63 | Recursion, integer arith |
| Queens | 78 | Backtracking, arrays |
| Sieve | 52 | Loop optimization, arrays |
| Storage | 53 | Allocation churn, GC pressure |
| Towers | 95 | Stack-like recursion |
| DeltaBlue | 670 | Polymorphic dispatch |
| Richards | 437 | OS-style task scheduler, polymorphism |
| Json | 528 | Parser, allocation, dispatch |
| Havlak | 496 | Loop recognition |
| CD | 844 | Realistic OO (collision detection) |

Total: ~3.8 KLOC of Ruby — port surface area for Erlang.

## Running the Ruby reference

From `upstream/benchmarks/Ruby/`:

```
ruby harness.rb Bounce     1 100   # 1 outer iteration, 100 inner iterations
ruby harness.rb DeltaBlue  1 100
ruby harness.rb Richards   1 5
```

Output format:
```
Starting Bounce benchmark ...
Bounce: iterations=1 runtime: 35584us
```

The `inner_iterations` count amortizes startup; AWFY's `rebench.conf`
specifies appropriate defaults per benchmark.

## What still needs to be built (Erlang side)

Nothing yet — this folder is just the upstream submodule + tool pin.
Per the plan in #32:

1. Port small benchmarks first (Bounce, Towers, Permute, Queens, Sieve,
   Mandelbrot, NBody, Storage).
2. Port polymorphic-heavy benchmarks (Richards, DeltaBlue) preserving
   dispatch shape.
3. Port the larger ones (Json, CD, Havlak).
4. Write a harness matching AWFY's measurement protocol.
5. Run on T1 + T2 + reference languages and commit numbers.
