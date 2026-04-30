# AWFY Port — Progress Tracker

Live progress for the AWFY port. Updated as work proceeds. When all
boxes are checked, this file can be deleted.

## Phase 1 — Remaining benchmark ports

### Json (parser + polymorphic JsonValue hierarchy, self-contained)
- [x] Extract `RAP_BENCHMARK_MINIFIED` test string to `priv/rap_benchmark.json` (25.8 KB)
- [ ] Port HashIndexTable (Erlang + Elixir)
- [ ] Port Parser with stateful read loop (Erlang + Elixir)
- [ ] Port JsonValue hierarchy as tagged records (Erlang + Elixir)
- [ ] verify_result/1: result.is_object && head.is_object && operations.size == 156
- [ ] Tests pass
- [ ] Commit

### SOM Set + IdentitySet
- [ ] `awfy_som_set.erl` — Set wrapping Vector, contains uses `==`
- [ ] `awfy_som_identity_set.erl` — IdentitySet, contains uses `=:=` / `===`
- [ ] `Awfy.Som.Set` + `Awfy.Som.IdentitySet`
- [ ] Tests
- [ ] Commit

### SOM Dictionary + IdentityDictionary
- [ ] `awfy_som_dict.erl` — chained-bucket hash table. custom_hash on keys.
- [ ] `awfy_som_identity_dict.erl` — uses identity-based key match.
- [ ] `Awfy.Som.Dictionary` + `Awfy.Som.IdentityDictionary`
- [ ] Tests
- [ ] Commit

### Havlak (loop recognizer)
- [x] BasicBlock, BasicBlockEdge, ControlFlowGraph
- [x] LoopStructureGraph, SimpleLoop
- [x] UnionFindNode
- [x] LoopTesterApp + HavlakLoopFinder (the algorithm proper)
- [x] verify_result/2 — InnerIter-dependent
- [x] Tests pass at InnerIter=1 (expected `[1605, 5213]`)
- [x] Commit

### DeltaBlue (constraint solver)
- [ ] Plan extends Vector, Sym, Strength
- [ ] AbstractConstraint + 5 subclasses (UnaryConstraint, BinaryConstraint, EditConstraint, ScaleConstraint, EqualityConstraint, StayConstraint)
- [ ] Variable
- [ ] Planner (chain_test + projection_test)
- [ ] verify_result/1
- [ ] Tests pass
- [ ] Commit

### CD (collision detection, self-contained)
- [ ] Vector2D, Vector3D
- [ ] Custom RedBlackTree (Node, RbtEntry, InsertResult)
- [ ] CallSign, Collision, CollisionDetector
- [ ] Motion, Aircraft, Simulator
- [ ] verify_result/2 — InnerIter-dependent
- [ ] Tests pass
- [ ] Commit

## Phase 2 — Optimization pass

After all 14 are working, do a uniform pass on each looking for:

- [ ] **Run erlc with options that report when destructive (in-place) tuple/binary
      updates are applied** (`+'{eep,...}' ` / `+bin_opt_info` / `+recv_opt_info` /
      `+inline_list_funcs` etc., and whatever flag exposes the "single-use record
      update" / writable-binary optimisation). Audit each benchmark's hot path
      to see whether `setelement/3`, record updates, and `<<Buf::binary, X>>`
      get the in-place treatment — these can be order-of-magnitude wins. Restructure
      hot loops so the compiler can prove the previous version is dead.
- [ ] Replace `lists:foldl` with explicit recursion in hot paths if measured faster
- [ ] Use binary pattern matching for Json's character reading (idiomatic + likely faster than charlist indexing)
- [ ] Use `:atomics` for Sieve where Boolean array is hot (only if it doesn't break the algorithm — `:array` is closer to Ruby semantics)
- [ ] Consider `Record` for Elixir struct-heavy benchmarks (List, NBody, Richards) — but this would cross the language line; keep struct as-is for ideomatic comparison
- [ ] Tail-call audit: every recursive function should be tail-call-optimizable; non-TC recursion adds stack growth and is slower
- [ ] Constant folding in Elixir: `@solar_mass 4.0 * @pi * @pi` should be evaluated at compile time
- [ ] In Erlang: prefer `case` over `if` when pattern matching over multiple values; the JIT specialises better
- [ ] In Elixir: prefer pattern-matching function heads over `cond` for hot dispatch
- [ ] Audit each verify_result for FP-determinism issues (NBody had one)

The rule throughout: **algorithmic fidelity to the AWFY Ruby source is sacred**. Don't change data structures (e.g. don't replace tuple+setelement with maps "because they're nicer"); don't drop polymorphic dispatch; don't replace state-threading with the process dictionary.

OK to change:
- Erlang/Elixir-specific syntactic preferences (case vs if, pattern match vs cond)
- Idiomatic stdlib usage (binary pattern matching where it's the natural BEAM way)
- Memoizing constants at compile time

NOT OK to change:
- Algorithm shape (e.g. don't replace HashIndexTable with `:maps`)
- Data structures (keep records as records, structs as structs, Vector as Vector)
- Number of recursive calls or loops in hot paths
- Order of operations in float arithmetic (FP-determinism)

## Phase 3 — Final report

- [ ] Update README with all 14 benchmarks' numbers
- [ ] Geometric mean across the suite
- [ ] Side-by-side comparison with Ruby (no YJIT)
- [ ] Commit
