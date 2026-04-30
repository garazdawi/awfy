%% Deterministic LCG matching SOM's Random class. Seed = 74755.
%%
%% Pure-functional: next/1 returns {Value, NewSeed}.
-module(awfy_random).

-export([new/0, next/1]).

-spec new() -> non_neg_integer().
new() ->
    74755.

-spec next(non_neg_integer()) -> {non_neg_integer(), non_neg_integer()}.
next(Seed) ->
    NewSeed = ((Seed * 1309) + 13849) band 65535,
    {NewSeed, NewSeed}.
