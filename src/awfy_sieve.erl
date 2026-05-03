%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% Sieve of Eratosthenes — translated from upstream/benchmarks/Ruby/sieve.rb.
%%
%% Counts primes up to 5000 using a 5000-element flag array. Mutable
%% array semantics map to the persistent `array` module — the natural
%% BEAM equivalent of Ruby's `Array.new`. (Phase 2: tried a flat tuple
%% with setelement, hoping for the JIT's destructive-update
%% optimization. With Erlang/OTP 28 it didn't kick in across the
%% sieve_loop/mark recursion, and the run got ~25× slower. Keeping
%% array for now.)
-module(awfy_sieve).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

-define(SIZE, 5000).

name() -> "Sieve".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    Result =:= 669.

benchmark() ->
    Flags = array:new(?SIZE, [{default, true}]),
    sieve(Flags, ?SIZE).

sieve(Flags, Size) ->
    sieve_loop(2, Size, Flags, 0).

sieve_loop(I, Size, _Flags, PrimeCount) when I > Size ->
    PrimeCount;
sieve_loop(I, Size, Flags, PrimeCount) ->
    case array:get(I - 1, Flags) of
        true ->
            Flags1 = mark(I + I, I, Size, Flags),
            sieve_loop(I + 1, Size, Flags1, PrimeCount + 1);
        false ->
            sieve_loop(I + 1, Size, Flags, PrimeCount)
    end.

mark(K, _Step, Size, Flags) when K > Size ->
    Flags;
mark(K, Step, Size, Flags) ->
    mark(K + Step, Step, Size, array:set(K - 1, false, Flags)).
