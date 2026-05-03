%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% Storage — translated from upstream/benchmarks/Ruby/storage.rb.
%%
%% Recursively builds a tree of arrays. Stresses allocation and GC,
%% since the result is discarded at every recursion level. Expected
%% count is 5461 (= 1 + 4 + 16 + ... + 4^6 with depth 7).
%%
%% Ruby `Array.new(N)` is nil-filled; we use a tuple of nils, which
%% is the BEAM equivalent of a heap-allocated fixed-size array.
-module(awfy_storage).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

name() -> "Storage".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    Result =:= 5461.

benchmark() ->
    Seed = awfy_random:new(),
    {_Tree, _Seed1, Count} = build_tree_depth(7, Seed, 0),
    Count.

build_tree_depth(1, Seed, Count) ->
    {N, Seed1} = awfy_random:next(Seed),
    Size = (N rem 10) + 1,
    {list_to_tuple(lists:duplicate(Size, nil)), Seed1, Count + 1};
build_tree_depth(Depth, Seed, Count) ->
    Count1 = Count + 1,
    {C0, Seed1, Count2} = build_tree_depth(Depth - 1, Seed, Count1),
    {C1, Seed2, Count3} = build_tree_depth(Depth - 1, Seed1, Count2),
    {C2, Seed3, Count4} = build_tree_depth(Depth - 1, Seed2, Count3),
    {C3, Seed4, Count5} = build_tree_depth(Depth - 1, Seed3, Count4),
    {{C0, C1, C2, C3}, Seed4, Count5}.
