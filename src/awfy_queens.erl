%% Eight Queens — translated from upstream/benchmarks/Ruby/queens.rb.
%%
%% Solves the 8-queens problem 10 times. Returns true if all 10 runs
%% find a valid placement. Boolean arrays are 8 or 16 elements, so we
%% use tuples + setelement (cheap at this size).
-module(awfy_queens).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

-record(state, {free_rows, free_maxs, free_mins, queen_rows}).

name() -> "Queens".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    Result.

benchmark() ->
    run(10, true).

run(0, Acc) ->
    Acc;
run(N, false) ->
    run(N - 1, false);
run(N, true) ->
    run(N - 1, queens()).

queens() ->
    State = #state{
        free_rows = list_to_tuple(lists:duplicate(8, true)),
        free_maxs = list_to_tuple(lists:duplicate(16, true)),
        free_mins = list_to_tuple(lists:duplicate(16, true)),
        queen_rows = list_to_tuple(lists:duplicate(8, -1))
    },
    {Result, _State1} = place_queen(0, State),
    Result.

place_queen(C, State) ->
    place_queen_row(0, C, State).

place_queen_row(8, _C, State) ->
    {false, State};
place_queen_row(R, C, State) ->
    case get_row_column(R, C, State) of
        true ->
            State1 = set_queen_row(R, C, State),
            State2 = set_row_column(R, C, false, State1),
            case C of
                7 ->
                    {true, State2};
                _ ->
                    case place_queen(C + 1, State2) of
                        {true, State3} ->
                            {true, State3};
                        {false, State3} ->
                            State4 = set_row_column(R, C, true, State3),
                            place_queen_row(R + 1, C, State4)
                    end
            end;
        false ->
            place_queen_row(R + 1, C, State)
    end.

get_row_column(R, C, #state{free_rows = FR, free_maxs = FMx, free_mins = FMn}) ->
    element(R + 1, FR) andalso
        element(C + R + 1, FMx) andalso
        element(C - R + 7 + 1, FMn).

set_row_column(R, C, V, State = #state{free_rows = FR, free_maxs = FMx, free_mins = FMn}) ->
    State#state{
        free_rows = setelement(R + 1, FR, V),
        free_maxs = setelement(C + R + 1, FMx, V),
        free_mins = setelement(C - R + 7 + 1, FMn, V)
    }.

set_queen_row(R, C, State = #state{queen_rows = QR}) ->
    State#state{queen_rows = setelement(R + 1, QR, C)}.
