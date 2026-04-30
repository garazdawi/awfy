%% CD — translated from upstream/benchmarks/Ruby/cd.rb.
%%
%% Aircraft collision detection. The Ruby version is heavily mutation-
%% based: a custom RedBlackTree with mutable Node objects (parent/left/
%% right/color), CollisionDetector keeps mutable state across frames,
%% Vector2D/3D allocations everywhere.
%%
%% BEAM port: every Node gets an integer id; the RBT carries a map
%% of nodes plus root id; every "mutation" rewrites the node back into
%% the map. The collision-detection state (the RBT keyed by callsign)
%% is threaded explicitly through frames.
%%
%% Vectors are simple records — value semantics is exactly what the
%% Ruby uses (its Vector2D/3D have only attr_reader, no mutators).
-module(awfy_cd).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/1, verify_result/2]).

-define(MIN_X, 0.0).
-define(MIN_Y, 0.0).
-define(MAX_X, 1000.0).
-define(MAX_Y, 1000.0).
-define(MIN_Z, 0.0).
-define(MAX_Z, 10.0).
-define(PROXIMITY_RADIUS, 1.0).
-define(GOOD_VOXEL_SIZE, 2.0).      %% PROXIMITY_RADIUS * 2.0
-define(HORIZONTAL, {v2, ?GOOD_VOXEL_SIZE, 0.0}).
-define(VERTICAL,   {v2, 0.0, ?GOOD_VOXEL_SIZE}).

-record(node, {
    id,
    key,
    value,
    left = nil,
    right = nil,
    parent = nil,
    color = red
}).

-record(rbt, {
    root = nil,
    next_id = 0,
    nodes = #{}
}).

%% Vector2D as {v2, X, Y}; Vector3D as {v3, X, Y, Z}.
%% CallSign as {cs, Int}. Aircraft as {aircraft, CallSign, Position3D}.
%% Motion as {motion, CallSign, PosOne3D, PosTwo3D}.
%% Collision as {collision, CallSignA, CallSignB, Position3D}.
%% RbtEntry yielded by for_each as {entry, Key, Value}.

name() -> "CD".

inner_benchmark_loop(N) ->
    Result = benchmark(N),
    verify_result(Result, N).

verify_result(C, 1000) -> C =:= 14484;
verify_result(C, 500) -> C =:= 14484;
verify_result(C, 250) -> C =:= 10830;
verify_result(C, 200) -> C =:= 8655;
verify_result(C, 100) -> C =:= 4305;
verify_result(C, 10) -> C =:= 390;
verify_result(C, 2) -> C =:= 42;
verify_result(_, _) -> false.

benchmark(NumAircrafts) ->
    NumFrames = 200,
    Simulator = simulator_new(NumAircrafts),
    State = rbt_new(),
    run_frames(0, NumFrames, Simulator, State, 0).

run_frames(I, N, _Sim, _State, Acc) when I >= N -> Acc;
run_frames(I, N, Sim, State, Acc) ->
    Time = I / 10.0,
    Frame = simulate(Sim, Time),
    {Collisions, State1} = handle_new_frame(Frame, State),
    run_frames(I + 1, N, Sim, State1, Acc + length(Collisions)).

%%======================================================================
%% Vector2D / Vector3D
%%======================================================================
v2_plus({v2, X1, Y1}, {v2, X2, Y2}) -> {v2, X1 + X2, Y1 + Y2}.
v2_minus({v2, X1, Y1}, {v2, X2, Y2}) -> {v2, X1 - X2, Y1 - Y2}.

%% Both V2 and CS use Erlang's natural term ordering: tuples compare
%% lexicographically, ints arithmetically. Drops the explicit
%% compare_to fun the Ruby uses (this benchmark never produces NaN
%% floats, where the BEAM's ordering would differ from Ruby's).

v3_plus({v3, X1, Y1, Z1}, {v3, X2, Y2, Z2}) -> {v3, X1 + X2, Y1 + Y2, Z1 + Z2}.
v3_minus({v3, X1, Y1, Z1}, {v3, X2, Y2, Z2}) -> {v3, X1 - X2, Y1 - Y2, Z1 - Z2}.
v3_dot({v3, X1, Y1, Z1}, {v3, X2, Y2, Z2}) -> X1 * X2 + Y1 * Y2 + Z1 * Z2.
v3_squared_magnitude(V) -> v3_dot(V, V).
v3_magnitude(V) -> math:sqrt(v3_squared_magnitude(V)).
v3_times({v3, X, Y, Z}, A) -> {v3, X * A, Y * A, Z * A}.

%%======================================================================
%% RedBlackTree
%%======================================================================
rbt_new() -> #rbt{}.

rbt_get_node(Id, #rbt{nodes = M}) -> maps:get(Id, M).

rbt_put_node(N = #node{id = Id}, T) ->
    T#rbt{nodes = maps:put(Id, N, T#rbt.nodes)}.

rbt_new_node(Key, Value, T) ->
    Id = T#rbt.next_id,
    N = #node{id = Id, key = Key, value = Value},
    {N, T#rbt{next_id = Id + 1, nodes = maps:put(Id, N, T#rbt.nodes)}}.

%% Set field on node by id, returns updated tree.
%% For left/right/parent, Val is a node id or nil.
set_field(NodeId, Field, Val, T) ->
    N = rbt_get_node(NodeId, T),
    N1 =
        case Field of
            left -> N#node{left = Val};
            right -> N#node{right = Val};
            parent -> N#node{parent = Val};
            color -> N#node{color = Val};
            value -> N#node{value = Val}
        end,
    rbt_put_node(N1, T).

get_field(NodeId, Field, T) ->
    N = rbt_get_node(NodeId, T),
    case Field of
        left -> N#node.left;
        right -> N#node.right;
        parent -> N#node.parent;
        color -> N#node.color;
        value -> N#node.value;
        key -> N#node.key
    end.

color_of(nil, _T) -> black;
color_of(Id, T) -> get_field(Id, color, T).

%% rbt_put: returns {OldValue|nil, T1}.
%% Uses Erlang's natural term ordering (`<`, `==`) for keys, since
%% both CallSign={cs,Int} and Vector2D={v2,X,Y} compare correctly
%% lexicographically and no NaN floats appear in this benchmark.
rbt_put(Key, Value, T0) ->
    {Result, T1} = tree_insert(Key, Value, T0),
    case Result of
        {existing, OldValue} ->
            {OldValue, T1};
        {new, NewNodeId} ->
            T2 = put_fixup(NewNodeId, T1),
            T3 = set_field(T2#rbt.root, color, black, T2),
            {nil, T3}
    end.

tree_insert(Key, Value, T0) ->
    case T0#rbt.root of
        nil ->
            {N, T1} = rbt_new_node(Key, Value, T0),
            {{new, N#node.id}, T1#rbt{root = N#node.id}};
        Root ->
            tree_insert_walk(Root, Key, Value, T0)
    end.

tree_insert_walk(Cur, Key, Value, T) ->
    XKey = get_field(Cur, key, T),
    if
        Key < XKey ->
            case get_field(Cur, left, T) of
                nil -> insert_at(Cur, left, Key, Value, T);
                L -> tree_insert_walk(L, Key, Value, T)
            end;
        Key > XKey ->
            case get_field(Cur, right, T) of
                nil -> insert_at(Cur, right, Key, Value, T);
                R -> tree_insert_walk(R, Key, Value, T)
            end;
        true ->
            OldValue = get_field(Cur, value, T),
            T1 = set_field(Cur, value, Value, T),
            {{existing, OldValue}, T1}
    end.

insert_at(ParentId, Side, Key, Value, T0) ->
    {N, T1} = rbt_new_node(Key, Value, T0),
    NewId = N#node.id,
    T2 = set_field(NewId, parent, ParentId, T1),
    T3 = set_field(ParentId, Side, NewId, T2),
    {{new, NewId}, T3}.

%% put_fixup — RBT fixup after insertion.
put_fixup(X, T) ->
    case fixup_step(X, T) of
        {done, T1} -> T1;
        {cont, X1, T1} -> put_fixup(X1, T1)
    end.

fixup_step(X, T) ->
    Root = T#rbt.root,
    case X =:= Root of
        true -> {done, T};
        false ->
            P = get_field(X, parent, T),
            case color_of(P, T) of
                black -> {done, T};
                red ->
                    PP = get_field(P, parent, T),
                    case PP of
                        nil -> {done, T};
                        _ ->
                            PPLeft = get_field(PP, left, T),
                            case P =:= PPLeft of
                                true ->
                                    Y = get_field(PP, right, T),
                                    case Y =/= nil andalso color_of(Y, T) =:= red of
                                        true ->
                                            T1 = set_field(P, color, black, T),
                                            T2 = set_field(Y, color, black, T1),
                                            T3 = set_field(PP, color, red, T2),
                                            {cont, PP, T3};
                                        false ->
                                            {X1, T1} =
                                                case X =:= get_field(P, right, T) of
                                                    true ->
                                                        T0 = left_rotate(P, T),
                                                        {P, T0};
                                                    false ->
                                                        {X, T}
                                                end,
                                            P1 = get_field(X1, parent, T1),
                                            T2 = set_field(P1, color, black, T1),
                                            PP1 = get_field(P1, parent, T2),
                                            T3 = set_field(PP1, color, red, T2),
                                            T4 = right_rotate(PP1, T3),
                                            {cont, X1, T4}
                                    end;
                                false ->
                                    Y = get_field(PP, left, T),
                                    case Y =/= nil andalso color_of(Y, T) =:= red of
                                        true ->
                                            T1 = set_field(P, color, black, T),
                                            T2 = set_field(Y, color, black, T1),
                                            T3 = set_field(PP, color, red, T2),
                                            {cont, PP, T3};
                                        false ->
                                            {X1, T1} =
                                                case X =:= get_field(P, left, T) of
                                                    true ->
                                                        T0 = right_rotate(P, T),
                                                        {P, T0};
                                                    false ->
                                                        {X, T}
                                                end,
                                            P1 = get_field(X1, parent, T1),
                                            T2 = set_field(P1, color, black, T1),
                                            PP1 = get_field(P1, parent, T2),
                                            T3 = set_field(PP1, color, red, T2),
                                            T4 = left_rotate(PP1, T3),
                                            {cont, X1, T4}
                                    end
                            end
                    end
            end
    end.

%% left_rotate(X, T) — Ruby's left_rotate.
left_rotate(X, T0) ->
    Y = get_field(X, right, T0),
    YLeft = get_field(Y, left, T0),
    %% x.right = y.left
    T1 = set_field(X, right, YLeft, T0),
    T2 =
        case YLeft of
            nil -> T1;
            _ -> set_field(YLeft, parent, X, T1)
        end,
    XParent = get_field(X, parent, T2),
    T3 = set_field(Y, parent, XParent, T2),
    T4 =
        case XParent of
            nil ->
                T3#rbt{root = Y};
            _ ->
                case X =:= get_field(XParent, left, T3) of
                    true -> set_field(XParent, left, Y, T3);
                    false -> set_field(XParent, right, Y, T3)
                end
        end,
    T5 = set_field(Y, left, X, T4),
    set_field(X, parent, Y, T5).

right_rotate(Y, T0) ->
    X = get_field(Y, left, T0),
    XRight = get_field(X, right, T0),
    T1 = set_field(Y, left, XRight, T0),
    T2 =
        case XRight of
            nil -> T1;
            _ -> set_field(XRight, parent, Y, T1)
        end,
    YParent = get_field(Y, parent, T2),
    T3 = set_field(X, parent, YParent, T2),
    T4 =
        case YParent of
            nil ->
                T3#rbt{root = X};
            _ ->
                case Y =:= get_field(YParent, left, T3) of
                    true -> set_field(YParent, left, X, T3);
                    false -> set_field(YParent, right, X, T3)
                end
        end,
    T5 = set_field(X, right, Y, T4),
    set_field(Y, parent, X, T5).

%% rbt_get(Key, T) — returns value or nil.
rbt_get(Key, T) ->
    case find_node(Key, T#rbt.root, T) of
        nil -> nil;
        Id -> get_field(Id, value, T)
    end.

find_node(_Key, nil, _T) -> nil;
find_node(Key, Cur, T) ->
    XKey = get_field(Cur, key, T),
    if
        Key == XKey -> Cur;
        Key < XKey -> find_node(Key, get_field(Cur, left, T), T);
        true -> find_node(Key, get_field(Cur, right, T), T)
    end.

%% rbt_remove(Key, T) — returns {Value | nil, T1}.
rbt_remove(Key, T0) ->
    case find_node(Key, T0#rbt.root, T0) of
        nil ->
            {nil, T0};
        Z ->
            ZLeft = get_field(Z, left, T0),
            ZRight = get_field(Z, right, T0),
            ZValue = get_field(Z, value, T0),
            Y =
                case ZLeft =:= nil orelse ZRight =:= nil of
                    true -> Z;
                    false -> tree_minimum(ZRight, T0)
                end,
            YLeft = get_field(Y, left, T0),
            YRight = get_field(Y, right, T0),
            X =
                case YLeft of
                    nil -> YRight;
                    _ -> YLeft
                end,
            YParent = get_field(Y, parent, T0),
            {T1, XParent} =
                case X of
                    nil -> {T0, YParent};
                    _ ->
                        Tn = set_field(X, parent, YParent, T0),
                        {Tn, YParent}
                end,
            T2 =
                case YParent of
                    nil ->
                        T1#rbt{root = nid_or_nil(X)};
                    _ ->
                        case Y =:= get_field(YParent, left, T1) of
                            true -> set_field(YParent, left, X, T1);
                            false -> set_field(YParent, right, X, T1)
                        end
                end,
            YColor = get_field(Y, color, T2),
            T3 =
                case Y =/= Z of
                    true ->
                        T_a =
                            case YColor of
                                black -> remove_fixup(X, XParent, T2);
                                _ -> T2
                            end,
                        ZParent = get_field(Z, parent, T_a),
                        ZColor = get_field(Z, color, T_a),
                        ZLeft1 = get_field(Z, left, T_a),
                        ZRight1 = get_field(Z, right, T_a),
                        T_b = set_field(Y, parent, ZParent, T_a),
                        T_c = set_field(Y, color, ZColor, T_b),
                        T_d = set_field(Y, left, ZLeft1, T_c),
                        T_e = set_field(Y, right, ZRight1, T_d),
                        T_f =
                            case ZLeft1 of
                                nil -> T_e;
                                _ -> set_field(ZLeft1, parent, Y, T_e)
                            end,
                        T_g =
                            case ZRight1 of
                                nil -> T_f;
                                _ -> set_field(ZRight1, parent, Y, T_f)
                            end,
                        case ZParent of
                            nil ->
                                T_g#rbt{root = Y};
                            _ ->
                                case Z =:= get_field(ZParent, left, T_g) of
                                    true -> set_field(ZParent, left, Y, T_g);
                                    false -> set_field(ZParent, right, Y, T_g)
                                end
                        end;
                    false ->
                        case YColor of
                            black -> remove_fixup(X, XParent, T2);
                            _ -> T2
                        end
                end,
            {ZValue, T3}
    end.

nid_or_nil(nil) -> nil;
nid_or_nil(Id) -> Id.

tree_minimum(Cur, T) ->
    case get_field(Cur, left, T) of
        nil -> Cur;
        L -> tree_minimum(L, T)
    end.

remove_fixup(X, XParent, T) ->
    case (X =/= T#rbt.root) andalso (X =:= nil orelse color_of(X, T) =:= black) of
        false ->
            case X of
                nil -> T;
                _ -> set_field(X, color, black, T)
            end;
        true ->
            case X =:= get_field(XParent, left, T) of
                true ->
                    fixup_left(X, XParent, T);
                false ->
                    fixup_right(X, XParent, T)
            end
    end.

fixup_left(_X, XParent, T) ->
    {W1, T1} = fixup_left_case1(get_field(XParent, right, T), XParent, T),
    WLeft = get_field(W1, left, T1),
    WRight = get_field(W1, right, T1),
    LBlack = (WLeft =:= nil) orelse color_of(WLeft, T1) =:= black,
    RBlack = (WRight =:= nil) orelse color_of(WRight, T1) =:= black,
    case LBlack andalso RBlack of
        true ->
            T2 = set_field(W1, color, red, T1),
            XP1 = get_field(XParent, parent, T2),
            remove_fixup(XParent, XP1, T2);
        false ->
            {W2, T2} = fixup_left_case3(W1, WLeft, WRight, XParent, T1),
            XPColor = get_field(XParent, color, T2),
            T3 = set_field(W2, color, XPColor, T2),
            T4 = set_field(XParent, color, black, T3),
            WRight1 = get_field(W2, right, T4),
            T5 =
                case WRight1 of
                    nil -> T4;
                    _ -> set_field(WRight1, color, black, T4)
                end,
            T6 = left_rotate(XParent, T5),
            X1 = T6#rbt.root,
            XP1 = get_field(X1, parent, T6),
            remove_fixup(X1, XP1, T6)
    end.

fixup_left_case1(W, XParent, T) ->
    case color_of(W, T) of
        red ->
            Ta = set_field(W, color, black, T),
            Tb = set_field(XParent, color, red, Ta),
            Tc = left_rotate(XParent, Tb),
            {get_field(XParent, right, Tc), Tc};
        _ ->
            {W, T}
    end.

fixup_left_case3(W1, WLeft, WRight, XParent, T1) ->
    case (WRight =:= nil) orelse color_of(WRight, T1) =:= black of
        true ->
            Ta = set_field(WLeft, color, black, T1),
            Tb = set_field(W1, color, red, Ta),
            Tc = right_rotate(W1, Tb),
            {get_field(XParent, right, Tc), Tc};
        false ->
            {W1, T1}
    end.

fixup_right(_X, XParent, T) ->
    {W1, T1} = fixup_right_case1(get_field(XParent, left, T), XParent, T),
    WLeft = get_field(W1, left, T1),
    WRight = get_field(W1, right, T1),
    RBlack = (WRight =:= nil) orelse color_of(WRight, T1) =:= black,
    LBlack = (WLeft =:= nil) orelse color_of(WLeft, T1) =:= black,
    case RBlack andalso LBlack of
        true ->
            T2 = set_field(W1, color, red, T1),
            XP1 = get_field(XParent, parent, T2),
            remove_fixup(XParent, XP1, T2);
        false ->
            {W2, T2} = fixup_right_case3(W1, WLeft, WRight, XParent, T1),
            XPColor = get_field(XParent, color, T2),
            T3 = set_field(W2, color, XPColor, T2),
            T4 = set_field(XParent, color, black, T3),
            WLeft1 = get_field(W2, left, T4),
            T5 =
                case WLeft1 of
                    nil -> T4;
                    _ -> set_field(WLeft1, color, black, T4)
                end,
            T6 = right_rotate(XParent, T5),
            X1 = T6#rbt.root,
            XP1 = get_field(X1, parent, T6),
            remove_fixup(X1, XP1, T6)
    end.

fixup_right_case1(W, XParent, T) ->
    case color_of(W, T) of
        red ->
            Ta = set_field(W, color, black, T),
            Tb = set_field(XParent, color, red, Ta),
            Tc = right_rotate(XParent, Tb),
            {get_field(XParent, left, Tc), Tc};
        _ ->
            {W, T}
    end.

fixup_right_case3(W1, WLeft, WRight, XParent, T1) ->
    case (WLeft =:= nil) orelse color_of(WLeft, T1) =:= black of
        true ->
            Ta = set_field(WRight, color, black, T1),
            Tb = set_field(W1, color, red, Ta),
            Tc = left_rotate(W1, Tb),
            {get_field(XParent, left, Tc), Tc};
        false ->
            {W1, T1}
    end.

%% rbt_for_each: iterate entries in key order, invoking Fun(Entry, Acc) -> Acc.
rbt_for_each(T, Fun, Acc0) ->
    case T#rbt.root of
        nil -> Acc0;
        Root ->
            Min = tree_minimum(Root, T),
            for_each_loop(Min, T, Fun, Acc0)
    end.

for_each_loop(nil, _T, _Fun, Acc) -> Acc;
for_each_loop(Cur, T, Fun, Acc) ->
    Entry = {entry, get_field(Cur, key, T), get_field(Cur, value, T)},
    Acc1 = Fun(Entry, Acc),
    Next = successor(Cur, T),
    for_each_loop(Next, T, Fun, Acc1).

successor(X, T) ->
    case get_field(X, right, T) of
        nil -> succ_walk_up(X, T);
        R -> tree_minimum(R, T)
    end.

succ_walk_up(X, T) ->
    case get_field(X, parent, T) of
        nil -> nil;
        Y ->
            case X =:= get_field(Y, right, T) of
                true -> succ_walk_up(Y, T);
                false -> Y
            end
    end.

%%======================================================================
%% Simulator / Frame
%%======================================================================
simulator_new(NumAircrafts) ->
    %% Just store the count; CallSigns are consecutive ints.
    {sim, NumAircrafts}.

simulate({sim, N}, Time) ->
    %% Frame: list of {aircraft, CallSign, Vector3D}. Step by 2 like Ruby.
    sim_step(0, N, Time, []).

sim_step(I, N, _Time, Acc) when I >= N -> lists:reverse(Acc);
sim_step(I, N, Time, Acc) ->
    Ac1 = {aircraft, {cs, I},
           {v3, Time, math:cos(Time) * 2.0 + I * 3.0, 10.0}},
    Ac2 = {aircraft, {cs, I + 1},
           {v3, Time, math:sin(Time) * 2.0 + I * 3.0, 10.0}},
    sim_step(I + 2, N, Time, [Ac2, Ac1 | Acc]).

%%======================================================================
%% CollisionDetector
%%======================================================================
%% State is the RBT keyed by callsign mapping to last position (Vector3D).

handle_new_frame(Frame, State0) ->
    %% Build motions from frame, keeping seen RBT.
    Seen0 = rbt_new(),
    {Motions, State1, Seen1} = build_motions(Frame, [], State0, Seen0),
    %% Remove aircraft no longer present.
    State2 = remove_unseen(State1, Seen1),
    %% Reduce collision set
    Reduced = reduce_collision_set(Motions),
    Collisions = find_collisions(Reduced),
    {Collisions, State2}.

build_motions([], Motions, State, Seen) -> {lists:reverse(Motions), State, Seen};
build_motions([{aircraft, CS, Pos} | Rest], Acc, State0, Seen0) ->
    {OldPosOpt, State1} = rbt_put(CS, Pos, State0),
    {_, Seen1} = rbt_put(CS, true, Seen0),
    OldPos =
        case OldPosOpt of
            nil -> Pos;
            P -> P
        end,
    Motion = {motion, CS, OldPos, Pos},
    build_motions(Rest, [Motion | Acc], State1, Seen1).

remove_unseen(State, Seen) ->
    %% Collect keys not in Seen
    ToRemove = rbt_for_each(State,
        fun({entry, K, _V}, Acc) ->
            case rbt_get(K, Seen) of
                nil -> [K | Acc];
                _ -> Acc
            end
        end,
        []
    ),
    lists:foldl(
        fun(K, S) ->
            {_, S1} = rbt_remove(K, S),
            S1
        end,
        State,
        ToRemove
    ).

%% reduce_collision_set: returns list of motion-lists (each list has size > 1).
reduce_collision_set(Motions) ->
    VoxelMap0 = rbt_new(),
    VoxelMap1 = lists:foldl(
        fun(M, VM) -> draw_motion_on_voxel_map(VM, M) end,
        VoxelMap0,
        Motions
    ),
    rbt_for_each(VoxelMap1,
        fun({entry, _K, V}, Acc) ->
            case length(V) > 1 of
                true -> [V | Acc];
                false -> Acc
            end
        end,
        []
    ).

draw_motion_on_voxel_map(VoxelMap, {motion, _CS, P1, _P2} = Motion) ->
    Seen0 = rbt_new(),
    {VoxelMap1, _Seen1} = recurse(VoxelMap, Seen0, voxel_hash(P1), Motion),
    VoxelMap1.

recurse(VoxelMap, Seen, NextVoxel, Motion) ->
    case is_in_voxel(NextVoxel, Motion) of
        false ->
            {VoxelMap, Seen};
        true ->
            {Old, Seen1} = rbt_put(NextVoxel, true, Seen),
            case Old of
                nil ->
                    VoxelMap1 = put_into_map(VoxelMap, NextVoxel, Motion),
                    {VoxelMap2, Seen2} = recurse(VoxelMap1, Seen1,
                        v2_minus(NextVoxel, ?HORIZONTAL), Motion),
                    {VoxelMap3, Seen3} = recurse(VoxelMap2, Seen2,
                        v2_plus(NextVoxel, ?HORIZONTAL), Motion),
                    {VoxelMap4, Seen4} = recurse(VoxelMap3, Seen3,
                        v2_minus(NextVoxel, ?VERTICAL), Motion),
                    {VoxelMap5, Seen5} = recurse(VoxelMap4, Seen4,
                        v2_plus(NextVoxel, ?VERTICAL), Motion),
                    {VoxelMap6, Seen6} = recurse(VoxelMap5, Seen5,
                        v2_minus(v2_minus(NextVoxel, ?HORIZONTAL), ?VERTICAL), Motion),
                    {VoxelMap7, Seen7} = recurse(VoxelMap6, Seen6,
                        v2_plus(v2_minus(NextVoxel, ?HORIZONTAL), ?VERTICAL), Motion),
                    {VoxelMap8, Seen8} = recurse(VoxelMap7, Seen7,
                        v2_minus(v2_plus(NextVoxel, ?HORIZONTAL), ?VERTICAL), Motion),
                    recurse(VoxelMap8, Seen8,
                        v2_plus(v2_plus(NextVoxel, ?HORIZONTAL), ?VERTICAL), Motion);
                _ ->
                    %% already seen — stop recursion
                    {VoxelMap, Seen1}
            end
    end.

put_into_map(VoxelMap, Voxel, Motion) ->
    %% Order doesn't affect the final collision count; prepend for O(1).
    case rbt_get(Voxel, VoxelMap) of
        nil ->
            {_, VM1} = rbt_put(Voxel, [Motion], VoxelMap),
            VM1;
        Existing ->
            {_, VM1} = rbt_put(Voxel, [Motion | Existing], VoxelMap),
            VM1
    end.

voxel_hash({v3, X, Y, _Z}) ->
    XDiv = trunc(X / ?GOOD_VOXEL_SIZE),
    YDiv = trunc(Y / ?GOOD_VOXEL_SIZE),
    Xv = ?GOOD_VOXEL_SIZE * XDiv,
    Yv = ?GOOD_VOXEL_SIZE * YDiv,
    Xv1 = case X < 0.0 of true -> Xv - ?GOOD_VOXEL_SIZE; false -> Xv end,
    Yv1 = case Y < 0.0 of true -> Yv - ?GOOD_VOXEL_SIZE; false -> Yv end,
    {v2, Xv1, Yv1}.

is_in_voxel({v2, Vx, Vy}, _) when Vx > ?MAX_X; Vx < ?MIN_X; Vy > ?MAX_Y; Vy < ?MIN_Y ->
    false;
is_in_voxel({v2, VX, VY}, {motion, _CS, {v3, X0, Y0, _}, {v3, FinX, FinY, _}}) ->
    Vs = ?GOOD_VOXEL_SIZE,
    R = ?PROXIMITY_RADIUS / 2.0,
    Xv = FinX - X0,
    Yv = FinY - Y0,
    %% Ruby relies on IEEE 754 ±Inf when Xv/Yv are 0; Erlang's `/`
    %% would crash and a 0.0 placeholder breaks the predicate. So
    %% guard each clause: only test the LowX/HighX-based parts when
    %% Xv =/= 0; same for Yv.
    XCond = x_cond(Xv, VX, X0, Vs, R),
    YCond = y_cond(Yv, VY, Y0, Vs, R),
    DiagCond = diag_cond(Xv, Yv, VX, VY, X0, Y0, Vs, R),
    XCond andalso YCond andalso DiagCond.

x_cond(+0.0, VX, X0, Vs, R) ->
    VX =< X0 + R andalso X0 - R =< VX + Vs;
x_cond(Xv, VX, X0, Vs, R) ->
    LowX0 = (VX - R - X0) / Xv,
    HighX0 = (VX + Vs + R - X0) / Xv,
    {LowX, HighX} =
        case Xv < 0.0 of
            true -> {HighX0, LowX0};
            false -> {LowX0, HighX0}
        end,
    (LowX =< 1.0 andalso 1.0 =< HighX)
        orelse (LowX =< 0.0 andalso 0.0 =< HighX)
        orelse (0.0 =< LowX andalso HighX =< 1.0).

y_cond(+0.0, VY, Y0, Vs, R) ->
    VY =< Y0 + R andalso Y0 - R =< VY + Vs;
y_cond(Yv, VY, Y0, Vs, R) ->
    LowY0 = (VY - R - Y0) / Yv,
    HighY0 = (VY + Vs + R - Y0) / Yv,
    {LowY, HighY} =
        case Yv < 0.0 of
            true -> {HighY0, LowY0};
            false -> {LowY0, HighY0}
        end,
    (LowY =< 1.0 andalso 1.0 =< HighY)
        orelse (LowY =< 0.0 andalso 0.0 =< HighY)
        orelse (0.0 =< LowY andalso HighY =< 1.0).

diag_cond(+0.0, _Yv, _VX, _VY, _X0, _Y0, _Vs, _R) -> true;
diag_cond(_Xv, +0.0, _VX, _VY, _X0, _Y0, _Vs, _R) -> true;
diag_cond(Xv, Yv, VX, VY, X0, Y0, Vs, R) ->
    LowX0 = (VX - R - X0) / Xv,
    HighX0 = (VX + Vs + R - X0) / Xv,
    {LowX, HighX} =
        case Xv < 0.0 of
            true -> {HighX0, LowX0};
            false -> {LowX0, HighX0}
        end,
    LowY0 = (VY - R - Y0) / Yv,
    HighY0 = (VY + Vs + R - Y0) / Yv,
    {LowY, HighY} =
        case Yv < 0.0 of
            true -> {HighY0, LowY0};
            false -> {LowY0, HighY0}
        end,
    (LowY =< HighX andalso HighX =< HighY)
        orelse (LowY =< LowX andalso LowX =< HighY)
        orelse (LowX =< LowY andalso HighY =< HighX).

%%======================================================================
%% Collision finding
%%======================================================================
find_collisions(Reduced) ->
    lists:foldl(fun find_in_group/2, [], Reduced).

find_in_group(Group, Acc) ->
    %% All unordered pairs by iterating the list and pairing each head
    %% with the rest — O(N²) without lists:nth.
    pair_outer(Group, Acc).

pair_outer([], Acc) -> Acc;
pair_outer([_], Acc) -> Acc;
pair_outer([M1 | Rest], Acc) ->
    Acc1 = pair_inner(M1, Rest, Acc),
    pair_outer(Rest, Acc1).

pair_inner(_M1, [], Acc) -> Acc;
pair_inner(M1, [M2 | Rest], Acc) ->
    Acc1 =
        case find_intersection(M1, M2) of
            nil -> Acc;
            Pos ->
                {motion, CSA, _, _} = M1,
                {motion, CSB, _, _} = M2,
                [{collision, CSA, CSB, Pos} | Acc]
        end,
    pair_inner(M1, Rest, Acc1).

%% find_intersection between two Motions, returns Vector3D or nil.
find_intersection({motion, _, Init1, P1Two}, {motion, _, Init2, P2Two}) ->
    Vec1 = v3_minus(P1Two, Init1),
    Vec2 = v3_minus(P2Two, Init2),
    Radius = ?PROXIMITY_RADIUS,
    A = v3_squared_magnitude(v3_minus(Vec2, Vec1)),
    case A /= 0.0 of
        true ->
            B = 2.0 * v3_dot(v3_minus(Init1, Init2), v3_minus(Vec1, Vec2)),
            C = -Radius * Radius + v3_squared_magnitude(v3_minus(Init2, Init1)),
            Discr = B * B - 4.0 * A * C,
            case Discr < 0.0 of
                true -> nil;
                false ->
                    SqrtD = math:sqrt(Discr),
                    V1 = (-B - SqrtD) / (2.0 * A),
                    V2 = (-B + SqrtD) / (2.0 * A),
                    case V1 =< V2 andalso
                         ((V1 =< 1.0 andalso 1.0 =< V2)
                          orelse (V1 =< 0.0 andalso 0.0 =< V2)
                          orelse (0.0 =< V1 andalso V2 =< 1.0)) of
                        true ->
                            V = case V1 =< 0.0 of true -> 0.0; false -> V1 end,
                            R1 = v3_plus(Init1, v3_times(Vec1, V)),
                            R2 = v3_plus(Init2, v3_times(Vec2, V)),
                            Result = v3_times(v3_plus(R1, R2), 0.5),
                            {v3, RX, RY, RZ} = Result,
                            case RX >= ?MIN_X andalso RX =< ?MAX_X
                                 andalso RY >= ?MIN_Y andalso RY =< ?MAX_Y
                                 andalso RZ >= ?MIN_Z andalso RZ =< ?MAX_Z of
                                true -> Result;
                                false -> nil
                            end;
                        false -> nil
                    end
            end;
        false ->
            %% planes parallel/stationary
            Dist = v3_magnitude(v3_minus(Init2, Init1)),
            case Dist =< Radius of
                true -> v3_times(v3_plus(Init1, Init2), 0.5);
                false -> nil
            end
    end.
