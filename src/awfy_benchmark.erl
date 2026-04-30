%% AWFY benchmark behaviour for Erlang ports.
%%
%% A benchmark module implements either:
%%   * benchmark/0 + verify_result/1, when the expected result does not
%%     depend on inner_iterations. The default inner_benchmark_loop/1
%%     calls benchmark + verify_result inner_iterations times.
%%   * inner_benchmark_loop/1 directly, when verification depends on
%%     inner_iterations (Mandelbrot, NBody, Havlak).
-module(awfy_benchmark).

-export([default_loop/2]).

-callback inner_benchmark_loop(InnerIter :: non_neg_integer()) -> boolean().
-callback name() -> string().

%% Default inner_benchmark_loop implementation: run benchmark/0 InnerIter
%% times, verify each result, fail fast if any does not match.
default_loop(_Mod, 0) ->
    true;
default_loop(Mod, N) when N > 0 ->
    case Mod:verify_result(Mod:benchmark()) of
        true -> default_loop(Mod, N - 1);
        false -> false
    end.
