%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% Towers of Hanoi — translated from upstream/benchmarks/Ruby/towers.rb.
%%
%% 13-disk tower, counts moves (expected 8191 = 2^13 - 1). The Ruby
%% original uses a TowersDisk linked-list with a mutable `next` field;
%% we use Erlang lists where the head is the top of the pile, with the
%% three piles held in a 3-tuple. Disks are just their integer size.
-module(awfy_towers).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

name() -> "Towers".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    Result =:= 8191.

benchmark() ->
    Piles0 = {[], [], []},
    Piles1 = build_tower_at(0, 13, Piles0),
    {_Piles2, Moves} = move_disks(13, 0, 1, Piles1, 0),
    Moves.

build_tower_at(_Pile, I, Piles) when I < 0 ->
    Piles;
build_tower_at(Pile, I, Piles) ->
    build_tower_at(Pile, I - 1, push_disk(I, Pile, Piles)).

push_disk(Disk, Pile, Piles) ->
    case top(Pile, Piles) of
        Top when is_integer(Top), Disk >= Top ->
            erlang:error('Cannot put a big disk on a smaller one');
        _ ->
            set_pile(Pile, [Disk | get_pile(Pile, Piles)], Piles)
    end.

pop_disk_from(Pile, Piles) ->
    case get_pile(Pile, Piles) of
        [] -> erlang:error('Attempting to remove a disk from an empty pile');
        [Top | Rest] -> {Top, set_pile(Pile, Rest, Piles)}
    end.

move_top_disk(From, To, Piles, Moves) ->
    {Disk, Piles1} = pop_disk_from(From, Piles),
    Piles2 = push_disk(Disk, To, Piles1),
    {Piles2, Moves + 1}.

move_disks(1, From, To, Piles, Moves) ->
    move_top_disk(From, To, Piles, Moves);
move_disks(Disks, From, To, Piles, Moves) ->
    Other = (3 - From) - To,
    {Piles1, Moves1} = move_disks(Disks - 1, From, Other, Piles, Moves),
    {Piles2, Moves2} = move_top_disk(From, To, Piles1, Moves1),
    move_disks(Disks - 1, Other, To, Piles2, Moves2).

%% Pile access (0-indexed); piles are a 3-tuple.
get_pile(0, {P, _, _}) -> P;
get_pile(1, {_, P, _}) -> P;
get_pile(2, {_, _, P}) -> P.

set_pile(0, P, {_, B, C}) -> {P, B, C};
set_pile(1, P, {A, _, C}) -> {A, P, C};
set_pile(2, P, {A, B, _}) -> {A, B, P}.

top(Pile, Piles) ->
    case get_pile(Pile, Piles) of
        [] -> nil;
        [T | _] -> T
    end.
