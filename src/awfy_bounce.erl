%% Bounce — translated from upstream/benchmarks/Ruby/bounce.rb.
%%
%% 100 balls bouncing inside a 500x500 box for 50 ticks. Returns the
%% number of times any ball hit a wall.
-module(awfy_bounce).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

-record(ball, {x, y, vx, vy}).

name() -> "Bounce".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Bounces) ->
    Bounces =:= 1331.

benchmark() ->
    Seed0 = awfy_random:new(),
    {Balls, Seed1} = init_balls(100, [], Seed0),
    _ = Seed1,
    run(50, Balls, 0).

%% Build N balls. Each ball consumes 4 random values (x, y, vx, vy);
%% mirror Ruby's Array.new(ball_count) { Ball.new(random) } order
%% exactly so the verification result matches.
init_balls(0, Acc, Seed) ->
    {lists:reverse(Acc), Seed};
init_balls(N, Acc, Seed) ->
    {Ball, Seed1} = new_ball(Seed),
    init_balls(N - 1, [Ball | Acc], Seed1).

new_ball(Seed0) ->
    {X, Seed1} = awfy_random:next(Seed0),
    {Y, Seed2} = awfy_random:next(Seed1),
    {VX, Seed3} = awfy_random:next(Seed2),
    {VY, Seed4} = awfy_random:next(Seed3),
    Ball = #ball{
        x = X rem 500,
        y = Y rem 500,
        vx = (VX rem 300) - 150,
        vy = (VY rem 300) - 150
    },
    {Ball, Seed4}.

run(0, _Balls, Bounces) ->
    Bounces;
run(Tick, Balls, Bounces) ->
    {NewBalls, TickBounces} = tick(Balls, [], 0),
    run(Tick - 1, NewBalls, Bounces + TickBounces).

tick([], Acc, Bounced) ->
    {lists:reverse(Acc), Bounced};
tick([Ball | Rest], Acc, Bounced) ->
    {NewBall, DidBounce} = bounce(Ball),
    Inc =
        case DidBounce of
            true -> 1;
            false -> 0
        end,
    tick(Rest, [NewBall | Acc], Bounced + Inc).

bounce(#ball{x = X0, y = Y0, vx = VX0, vy = VY0}) ->
    Limit = 500,
    X1 = X0 + VX0,
    Y1 = Y0 + VY0,
    {X2, VX1, B1} = clamp(X1, VX0, Limit, false),
    {Y2, VY1, B2} = clamp(Y1, VY0, Limit, B1),
    {#ball{x = X2, y = Y2, vx = VX1, vy = VY1}, B2}.

clamp(V, Vel, Limit, _Bounced) when V > Limit ->
    {Limit, -abs(Vel), true};
clamp(V, Vel, _Limit, _Bounced) when V < 0 ->
    {0, abs(Vel), true};
clamp(V, Vel, _Limit, Bounced) ->
    {V, Vel, Bounced}.
