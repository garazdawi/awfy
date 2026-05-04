%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: Apache-2.0
%%
%% Plain Erlang harness for benchmarking against a non-host OTP.
%%
%% Lives under `src_target/` rather than `src/` because it's only
%% compiled by the *target* OTP's `erlc`, never by the host project's
%% mix-driven build. Keeping the source out of the regular `src/` tree
%% means `mix compile` doesn't pick it up — the host BEAMs and target
%% BEAMs end up in separate dirs and can be loaded together by a peer.
%%
%% Why a separate harness rather than reusing the existing
%% `Awfy.BencheeRunner` flow:
%%
%%   * The target VM may be OTP 20-23, where Elixir doesn't exist or
%%     ships a Precompiled.zip rather than `elixir-otp-XX.zip`.
%%   * The target VM may be OTP 24+ but with a BEAM file format the
%%     host's `mix compile` output can't be loaded against.
%%
%% So we keep the orchestration on the host (Elixir 1.19, modern OTP)
%% and shell out to the target VM with this harness on its code path.
%% The host hands us `(Module, InnerIter, IterCount)`; we time each
%% `Module:inner_benchmark_loop(InnerIter)` call with
%% `erlang:monotonic_time/1` (available since the OTP 18 nanosecond
%% time unit landed) and emit one nanosecond integer per line on
%% stdout.

-module(awfy_target_runner).

-export([run_iters/3, run_iters_io/3]).

%% Run `Module:inner_benchmark_loop(InnerIter)` IterCount times,
%% returning a list of nanosecond durations (one per outer iteration,
%% in order).
run_iters(Module, InnerIter, IterCount)
        when is_atom(Module),
             is_integer(InnerIter), InnerIter >= 0,
             is_integer(IterCount), IterCount > 0 ->
    %% Force a load so the first iteration isn't penalised by the
    %% on-demand loader. Errors here surface clearly to the host.
    case code:ensure_loaded(Module) of
        {module, Module} -> ok;
        {error, Reason} -> exit({load_failed, Module, Reason})
    end,
    loop(Module, InnerIter, IterCount, []).

loop(_M, _II, 0, Acc) ->
    lists:reverse(Acc);
loop(M, II, N, Acc) ->
    T0 = erlang:monotonic_time(nanosecond),
    case M:inner_benchmark_loop(II) of
        true ->
            T1 = erlang:monotonic_time(nanosecond),
            loop(M, II, N - 1, [T1 - T0 | Acc]);
        false ->
            exit({verify_failed, M, II});
        Other ->
            exit({unexpected_return, M, II, Other})
    end.

%% I/O variant — invoked from the host via `erl -eval`. Emits each
%% timing as a decimal integer on its own line, then halts. The host
%% reads stdout line-by-line; any non-integer line is treated as an
%% error message and surfaces to the user verbatim.
run_iters_io(Module, InnerIter, IterCount) ->
    try run_iters(Module, InnerIter, IterCount) of
        Times ->
            lists:foreach(fun(T) -> io:format("~B~n", [T]) end, Times),
            erlang:halt(0)
    catch
        %% 2-tuple form (no Stack) so this file compiles on OTP 20.
        %% The 3-tuple stacktrace catch syntax was introduced in OTP 21.
        Class:Reason ->
            io:format(standard_error,
                      "awfy_target_runner: ~p:~p~n",
                      [Class, Reason]),
            erlang:halt(1)
    end.
