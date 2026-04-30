%% NBody — translated from upstream/benchmarks/Ruby/nbody.rb.
%%
%% 5-body planetary simulation. Verification depends on inner_iterations:
%%   1      -> -0.16907495402506745
%%   250000 -> -0.1690859889909308
%%
%% Bodies are stored in a 5-tuple of body records. The advance and
%% energy loops are nested recursion over indices i and j>i, mirroring
%% the Ruby's nested each_index loops.
-module(awfy_nbody).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, verify_result/2]).

-record(body, {x, y, z, vx, vy, vz, mass}).

-define(PI, 3.141592653589793).
-define(SOLAR_MASS, (4.0 * ?PI * ?PI)).
-define(DAYS_PER_YEAR, 365.24).
-define(N_BODIES, 5).

name() -> "NBody".

inner_benchmark_loop(InnerIter) ->
    Bodies = create_bodies(),
    Bodies1 = run_steps(InnerIter, Bodies, 0.01),
    verify_result(energy(Bodies1), InnerIter).

verify_result(Result, 1) -> Result =:= -0.16907495402506745;
verify_result(Result, 250000) -> Result =:= -0.1690859889909308;
verify_result(_Result, _) -> false.

run_steps(0, Bodies, _Dt) -> Bodies;
run_steps(N, Bodies, Dt) -> run_steps(N - 1, advance(Bodies, Dt), Dt).

create_bodies() ->
    Bodies = {sun(), jupiter(), saturn(), uranus(), neptune()},
    {Px, Py, Pz} = momentum_loop(1, Bodies, 0.0, 0.0, 0.0),
    setelement(1, Bodies, offset_momentum(element(1, Bodies), Px, Py, Pz)).

%% Body constructors.
body(X, Y, Z, Vx, Vy, Vz, Mass) ->
    #body{
        x = X,
        y = Y,
        z = Z,
        vx = Vx * ?DAYS_PER_YEAR,
        vy = Vy * ?DAYS_PER_YEAR,
        vz = Vz * ?DAYS_PER_YEAR,
        mass = Mass * ?SOLAR_MASS
    }.

sun() -> body(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0).

jupiter() ->
    body(
        4.8414314424647209,
        -1.16032004402742839,
        -0.103622044471123109,
        0.00166007664274403694,
        0.00769901118419740425,
        -0.0000690460016972063023,
        0.000954791938424326609
    ).

saturn() ->
    body(
        8.34336671824457987,
        4.12479856412430479,
        -0.403523417114321381,
        -0.00276742510726862411,
        0.00499852801234917238,
        0.0000230417297573763929,
        0.000285885980666130812
    ).

uranus() ->
    body(
        12.894369562139131,
        -15.1111514016986312,
        -0.223307578892655734,
        0.00296460137564761618,
        0.0023784717395948095,
        -0.0000296589568540237556,
        0.0000436624404335156298
    ).

neptune() ->
    body(
        15.3796971148509165,
        -25.9193146099879641,
        0.179258772950371181,
        0.00268067772490389322,
        0.00162824170038242295,
        -0.000095159225451971587,
        0.0000515138902046611451
    ).

offset_momentum(B, Px, Py, Pz) ->
    B#body{
        vx = 0.0 - Px / ?SOLAR_MASS,
        vy = 0.0 - Py / ?SOLAR_MASS,
        vz = 0.0 - Pz / ?SOLAR_MASS
    }.

momentum_loop(I, _Bodies, Px, Py, Pz) when I > ?N_BODIES ->
    {Px, Py, Pz};
momentum_loop(I, Bodies, Px, Py, Pz) ->
    B = element(I, Bodies),
    momentum_loop(
        I + 1,
        Bodies,
        Px + B#body.vx * B#body.mass,
        Py + B#body.vy * B#body.mass,
        Pz + B#body.vz * B#body.mass
    ).

%% Advance: for each pair (i,j) with i<j, update both, then move all bodies.
advance(Bodies, Dt) ->
    Bodies1 = advance_i(1, Bodies, Dt),
    move_loop(1, Bodies1, Dt).

advance_i(I, Bodies, _Dt) when I >= ?N_BODIES ->
    Bodies;
advance_i(I, Bodies, Dt) ->
    Bodies1 = advance_j(I, I + 1, Bodies, Dt),
    advance_i(I + 1, Bodies1, Dt).

advance_j(_I, J, Bodies, _Dt) when J > ?N_BODIES ->
    Bodies;
advance_j(I, J, Bodies, Dt) ->
    Bodies1 = update_pair(I, J, Bodies, Dt),
    advance_j(I, J + 1, Bodies1, Dt).

update_pair(I, J, Bodies, Dt) ->
    Ib = element(I, Bodies),
    Jb = element(J, Bodies),
    Dx = Ib#body.x - Jb#body.x,
    Dy = Ib#body.y - Jb#body.y,
    Dz = Ib#body.z - Jb#body.z,
    DSq = Dx * Dx + Dy * Dy + Dz * Dz,
    Distance = math:sqrt(DSq),
    Mag = Dt / (DSq * Distance),
    %% Match the Ruby ordering exactly: ((d * j_mass) * mag), then sub.
    %% Pre-multiplying j_mass*mag here would change FP rounding and
    %% drift from the canonical AWFY result at high iter counts.
    Ib1 = Ib#body{
        vx = Ib#body.vx - Dx * Jb#body.mass * Mag,
        vy = Ib#body.vy - Dy * Jb#body.mass * Mag,
        vz = Ib#body.vz - Dz * Jb#body.mass * Mag
    },
    Jb1 = Jb#body{
        vx = Jb#body.vx + Dx * Ib#body.mass * Mag,
        vy = Jb#body.vy + Dy * Ib#body.mass * Mag,
        vz = Jb#body.vz + Dz * Ib#body.mass * Mag
    },
    setelement(J, setelement(I, Bodies, Ib1), Jb1).

move_loop(I, Bodies, _Dt) when I > ?N_BODIES ->
    Bodies;
move_loop(I, Bodies, Dt) ->
    B = element(I, Bodies),
    B1 = B#body{
        x = B#body.x + Dt * B#body.vx,
        y = B#body.y + Dt * B#body.vy,
        z = B#body.z + Dt * B#body.vz
    },
    move_loop(I + 1, setelement(I, Bodies, B1), Dt).

energy(Bodies) ->
    energy_loop(1, Bodies, 0.0).

energy_loop(I, _Bodies, E) when I > ?N_BODIES ->
    E;
energy_loop(I, Bodies, E) ->
    Ib = element(I, Bodies),
    Self =
        0.5 * Ib#body.mass *
            (Ib#body.vx * Ib#body.vx + Ib#body.vy * Ib#body.vy + Ib#body.vz * Ib#body.vz),
    E1 = E + Self,
    E2 = energy_inner(I, I + 1, Bodies, E1),
    energy_loop(I + 1, Bodies, E2).

energy_inner(_I, J, _Bodies, E) when J > ?N_BODIES ->
    E;
energy_inner(I, J, Bodies, E) ->
    Ib = element(I, Bodies),
    Jb = element(J, Bodies),
    Dx = Ib#body.x - Jb#body.x,
    Dy = Ib#body.y - Jb#body.y,
    Dz = Ib#body.z - Jb#body.z,
    Distance = math:sqrt(Dx * Dx + Dy * Dy + Dz * Dz),
    energy_inner(I, J + 1, Bodies, E - Ib#body.mass * Jb#body.mass / Distance).
