%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% List — translated from upstream/benchmarks/Ruby/list.rb.
%%
%% A custom singly-linked list with `val` and `next` fields, recursive
%% length, and a tail-recursive shape comparator. We deliberately use a
%% record rather than Erlang's native [H|T] lists — the benchmark is
%% testing pointer-chasing through a heap-allocated structure, and
%% native lists would short-circuit that with the JIT's list-specific
%% optimizations.
-module(awfy_list).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

-record(element, {val, next = nil}).

name() -> "List".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    Result =:= 10.

benchmark() ->
    Result = tail(
        make_list(15),
        make_list(10),
        make_list(6)
    ),
    length_of(Result).

make_list(0) ->
    nil;
make_list(N) ->
    #element{val = N, next = make_list(N - 1)}.

length_of(nil) ->
    0;
length_of(#element{next = Next}) ->
    1 + length_of(Next).

is_shorter_than(X, Y) ->
    is_shorter_loop(X, Y).

is_shorter_loop(_X, nil) ->
    false;
is_shorter_loop(nil, _Y) ->
    true;
is_shorter_loop(#element{next = XN}, #element{next = YN}) ->
    is_shorter_loop(XN, YN).

tail(X, Y, Z) ->
    case is_shorter_than(Y, X) of
        true ->
            tail(
                tail(X#element.next, Y, Z),
                tail(Y#element.next, Z, X),
                tail(Z#element.next, X, Y)
            );
        false ->
            Z
    end.
