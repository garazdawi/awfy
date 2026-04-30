%% Permute — translated from upstream/benchmarks/Ruby/permute.rb.
%%
%% Recursively counts permutations of a 6-element array. The Ruby
%% original swaps elements in a mutable array; we use a 6-tuple with
%% setelement/3 (cheap at this size — copying 6 words per swap).
-module(awfy_permute).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

name() -> "Permute".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    Result =:= 8660.

benchmark() ->
    V = list_to_tuple(lists:duplicate(6, 0)),
    {Count, _V1} = permute(6, 0, V),
    Count.

permute(0, Count, V) ->
    {Count + 1, V};
permute(N, Count, V) ->
    Count1 = Count + 1,
    N1 = N - 1,
    {Count2, V1} = permute(N1, Count1, V),
    permute_outer(N1, N1, Count2, V1).

permute_outer(I, _N1, Count, V) when I < 0 ->
    {Count, V};
permute_outer(I, N1, Count, V) ->
    V1 = swap(N1, I, V),
    {Count1, V2} = permute(N1, Count, V1),
    V3 = swap(N1, I, V2),
    permute_outer(I - 1, N1, Count1, V3).

%% Tuples are 1-indexed in Erlang; permute uses 0-indexed positions.
swap(I, J, V) ->
    I1 = I + 1,
    J1 = J + 1,
    Tmp = element(I1, V),
    V1 = setelement(I1, V, element(J1, V)),
    setelement(J1, V1, Tmp).
