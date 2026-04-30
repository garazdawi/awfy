%% DeltaBlue — translated from upstream/benchmarks/Ruby/deltablue.rb.
%%
%% Constraint propagation solver. Heavily mutation-based in Ruby:
%% Variable holds list of constraints, constraints hold variable refs,
%% Planner mutates current_mark, propagation walks the bidirectional
%% graph applying recalculate / execute as it goes.
%%
%% BEAM port: every "object" gets an integer id; a #world{} state holds
%% vars and cons maps, and threads through every operation. Polymorphic
%% constraint dispatch (recalculate/execute/choose_method/etc.) uses
%% tagged-tuple constraints with pattern matching — preserves the
%% dispatch shape without inheritance.
%%
%% Strength is just the arithmetic int (Sym kept implicit). The eight
%% named strengths map to ints via strength_arith/1.
%%
%% Verification: chain_test and projection_test both raise on assertion
%% failure, so reaching the end means correct. inner_benchmark_loop
%% returns true on success.
-module(awfy_deltablue).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

%% Strengths (just store the arithmetic value; comparison is enough).
-define(STR_ABS_STRONGEST, -10000).
-define(STR_REQUIRED, -800).
-define(STR_STRONG_PREFERRED, -600).
-define(STR_PREFERRED, -400).
-define(STR_STRONG_DEFAULT, -200).
-define(STR_DEFAULT, 0).
-define(STR_WEAK_DEFAULT, 500).
-define(STR_ABS_WEAKEST, 10000).

-record(var, {
    id,
    value = 0,
    constraints = [],         % list of constraint ids
    determined_by = nil,      % constraint id or nil
    walk_strength = ?STR_ABS_WEAKEST,
    stay = true,
    mark = 0
}).

-record(world, {
    next_id = 0,
    vars = #{},               % var id -> #var{}
    cons = #{},               % constraint id -> tagged tuple
    current_mark = 1
}).

%% Constraint shapes:
%%   {stay_c, Id, Strength, OutputId, Satisfied}
%%   {edit_c, Id, Strength, OutputId, Satisfied}
%%   {eq_c,   Id, Strength, V1Id, V2Id, Direction}     % Direction :: forward | backward | nil
%%   {scale_c, Id, Strength, V1Id, V2Id, ScaleId, OffsetId, Direction}

name() -> "DeltaBlue".

benchmark() -> ok.

inner_benchmark_loop(N) ->
    chain_test(N),
    projection_test(N),
    verify_result(true).

verify_result(true) -> true;
verify_result(_) -> false.

%%======================================================================
%% Strength helpers
%%======================================================================
strength_same(A, B) -> A =:= B.
strength_stronger(A, B) -> A < B.
strength_weaker(A, B) -> A > B.
strength_strongest(A, B) -> case strength_stronger(B, A) of true -> B; false -> A end.
-compile({nowarn_unused_function, [strength_strongest/2, strength_same/2]}).
strength_weakest(A, B) -> case strength_weaker(B, A) of true -> B; false -> A end.

%%======================================================================
%% World / Variable / Constraint primitives
%%======================================================================
new_world() -> #world{}.

new_var(W = #world{next_id = N, vars = M}) ->
    Var = #var{id = N},
    {N, W#world{next_id = N + 1, vars = maps:put(N, Var, M)}}.

new_var_with(Value, W) ->
    {Id, W1} = new_var(W),
    {Id, set_var_value(Id, Value, W1)}.

get_var(Id, #world{vars = M}) -> maps:get(Id, M).
put_var(V = #var{id = Id}, W) ->
    W#world{vars = maps:put(Id, V, W#world.vars)}.

set_var_value(Id, Value, W) ->
    V = get_var(Id, W),
    put_var(V#var{value = Value}, W).

set_var_field(Id, Field, Value, W) ->
    V = get_var(Id, W),
    V1 =
        case Field of
            value -> V#var{value = Value};
            walk_strength -> V#var{walk_strength = Value};
            stay -> V#var{stay = Value};
            mark -> V#var{mark = Value};
            determined_by -> V#var{determined_by = Value}
        end,
    put_var(V1, W).

var_add_constraint(VarId, CId, W) ->
    V = get_var(VarId, W),
    put_var(V#var{constraints = V#var.constraints ++ [CId]}, W).

var_remove_constraint(VarId, CId, W) ->
    V = get_var(VarId, W),
    Cs1 = lists:delete(CId, V#var.constraints),
    DB1 =
        case V#var.determined_by =:= CId of
            true -> nil;
            false -> V#var.determined_by
        end,
    put_var(V#var{constraints = Cs1, determined_by = DB1}, W).

new_id(W = #world{next_id = N}) -> {N, W#world{next_id = N + 1}}.

get_con(Id, #world{cons = M}) -> maps:get(Id, M).
put_con(C, W) -> W#world{cons = maps:put(con_id(C), C, W#world.cons)}.

con_id({stay_c, Id, _, _, _}) -> Id;
con_id({edit_c, Id, _, _, _}) -> Id;
con_id({eq_c, Id, _, _, _, _}) -> Id;
con_id({scale_c, Id, _, _, _, _, _, _}) -> Id.

con_strength({stay_c, _, S, _, _}) -> S;
con_strength({edit_c, _, S, _, _}) -> S;
con_strength({eq_c, _, S, _, _, _}) -> S;
con_strength({scale_c, _, S, _, _, _, _, _}) -> S.

new_mark(W = #world{current_mark = M}) ->
    M1 = M + 1,
    {M1, W#world{current_mark = M1}}.

%%======================================================================
%% Polymorphic constraint operations
%%======================================================================
is_input({edit_c, _, _, _, _}) -> true;
is_input(_) -> false.

is_satisfied({stay_c, _, _, _, S}) -> S;
is_satisfied({edit_c, _, _, _, S}) -> S;
is_satisfied({eq_c, _, _, _, _, D}) -> D =/= nil;
is_satisfied({scale_c, _, _, _, _, _, _, D}) -> D =/= nil.

mark_unsatisfied({stay_c, Id, S, O, _}) -> {stay_c, Id, S, O, false};
mark_unsatisfied({edit_c, Id, S, O, _}) -> {edit_c, Id, S, O, false};
mark_unsatisfied({eq_c, Id, S, V1, V2, _}) -> {eq_c, Id, S, V1, V2, nil};
mark_unsatisfied({scale_c, Id, S, V1, V2, Sc, Of, _}) -> {scale_c, Id, S, V1, V2, Sc, Of, nil}.

output({stay_c, _, _, O, _}) -> O;
output({edit_c, _, _, O, _}) -> O;
output({eq_c, _, _, V1, V2, D}) ->
    case D of
        forward -> V2;
        _ -> V1
    end;
output({scale_c, _, _, V1, V2, _, _, D}) ->
    case D of
        forward -> V2;
        _ -> V1
    end.

%% Returns updated world.
add_to_graph(C, W) ->
    case C of
        {stay_c, Id, S, O, _} ->
            W1 = var_add_constraint(O, Id, W),
            put_con({stay_c, Id, S, O, false}, W1);
        {edit_c, Id, S, O, _} ->
            W1 = var_add_constraint(O, Id, W),
            put_con({edit_c, Id, S, O, false}, W1);
        {eq_c, Id, S, V1, V2, _} ->
            W1 = var_add_constraint(V1, Id, W),
            W2 = var_add_constraint(V2, Id, W1),
            put_con({eq_c, Id, S, V1, V2, nil}, W2);
        {scale_c, Id, S, V1, V2, Sc, Of, _} ->
            W1 = var_add_constraint(V1, Id, W),
            W2 = var_add_constraint(V2, Id, W1),
            W3 = var_add_constraint(Sc, Id, W2),
            W4 = var_add_constraint(Of, Id, W3),
            put_con({scale_c, Id, S, V1, V2, Sc, Of, nil}, W4)
    end.

remove_from_graph(C, W) ->
    case C of
        {stay_c, Id, S, O, _} ->
            W1 = var_remove_constraint(O, Id, W),
            put_con({stay_c, Id, S, O, false}, W1);
        {edit_c, Id, S, O, _} ->
            W1 = var_remove_constraint(O, Id, W),
            put_con({edit_c, Id, S, O, false}, W1);
        {eq_c, Id, S, V1, V2, _} ->
            W1 = var_remove_constraint(V1, Id, W),
            W2 = var_remove_constraint(V2, Id, W1),
            put_con({eq_c, Id, S, V1, V2, nil}, W2);
        {scale_c, Id, S, V1, V2, Sc, Of, _} ->
            W1 = var_remove_constraint(V1, Id, W),
            W2 = var_remove_constraint(V2, Id, W1),
            W3 = var_remove_constraint(Sc, Id, W2),
            W4 = var_remove_constraint(Of, Id, W3),
            put_con({scale_c, Id, S, V1, V2, Sc, Of, nil}, W4)
    end.

%% choose_method: sets satisfied/direction on the constraint, returns updated world.
choose_method(C, Mark, W) ->
    case C of
        {stay_c, Id, S, O, _} ->
            OutV = get_var(O, W),
            Sat = OutV#var.mark =/= Mark andalso strength_stronger(S, OutV#var.walk_strength),
            put_con({stay_c, Id, S, O, Sat}, W);
        {edit_c, Id, S, O, _} ->
            OutV = get_var(O, W),
            Sat = OutV#var.mark =/= Mark andalso strength_stronger(S, OutV#var.walk_strength),
            put_con({edit_c, Id, S, O, Sat}, W);
        {eq_c, _Id, S, V1, V2, _} ->
            choose_binary(C, S, V1, V2, Mark, W);
        {scale_c, _Id, S, V1, V2, _, _, _} ->
            choose_binary(C, S, V1, V2, Mark, W)
    end.

choose_binary(C, S, V1, V2, Mark, W) ->
    V1V = get_var(V1, W),
    V2V = get_var(V2, W),
    Direction =
        case V1V#var.mark =:= Mark of
            true ->
                case V2V#var.mark =/= Mark andalso strength_stronger(S, V2V#var.walk_strength) of
                    true -> forward;
                    false -> nil
                end;
            false ->
                case V2V#var.mark =:= Mark of
                    true ->
                        case V1V#var.mark =/= Mark andalso strength_stronger(S, V1V#var.walk_strength) of
                            true -> backward;
                            false -> nil
                        end;
                    false ->
                        case strength_weaker(V1V#var.walk_strength, V2V#var.walk_strength) of
                            true ->
                                case strength_stronger(S, V1V#var.walk_strength) of
                                    true -> backward;
                                    false -> nil
                                end;
                            false ->
                                case strength_stronger(S, V2V#var.walk_strength) of
                                    true -> forward;
                                    false -> nil
                                end
                        end
                end
        end,
    C1 = set_direction(C, Direction),
    put_con(C1, W).

set_direction({eq_c, Id, S, V1, V2, _}, D) -> {eq_c, Id, S, V1, V2, D};
set_direction({scale_c, Id, S, V1, V2, Sc, Of, _}, D) -> {scale_c, Id, S, V1, V2, Sc, Of, D}.

%% inputs_do: returns list of var ids for unary it's empty; for binary
%% it depends on direction; for scale it's three.
inputs_list({stay_c, _, _, _, _}) -> [];
inputs_list({edit_c, _, _, _, _}) -> [];
inputs_list({eq_c, _, _, V1, V2, D}) ->
    case D of
        forward -> [V1];
        _ -> [V2]
    end;
inputs_list({scale_c, _, _, V1, V2, Sc, Of, D}) ->
    case D of
        forward -> [V1, Sc, Of];
        _ -> [V2, Sc, Of]
    end.

%% inputs_known: are all input var marks == mark or stay or no determined_by?
inputs_known(C, Mark, W) ->
    Inputs = inputs_list(C),
    %% inputs_has_one returns true if any input fails the predicate.
    %% inputs_known = !inputs_has_one { |v| !(...) }
    not lists:any(
        fun(VarId) ->
            V = get_var(VarId, W),
            not (V#var.mark =:= Mark orelse V#var.stay orelse V#var.determined_by =:= nil)
        end,
        Inputs
    ).

%% recalculate: returns updated world.
recalculate(C, W) ->
    case C of
        {stay_c, _Id, S, O, _Sat} ->
            W1 = set_var_field(O, walk_strength, S, W),
            W2 = set_var_field(O, stay, not is_input(C), W1),
            OutV = get_var(O, W2),
            case OutV#var.stay of
                true -> execute(get_con(con_id(C), W2), W2);
                false -> W2
            end;
        {edit_c, _Id, S, O, _Sat} ->
            W1 = set_var_field(O, walk_strength, S, W),
            W2 = set_var_field(O, stay, not is_input(C), W1),
            OutV = get_var(O, W2),
            case OutV#var.stay of
                true -> execute(get_con(con_id(C), W2), W2);
                false -> W2
            end;
        {eq_c, _Id, S, V1, V2, D} ->
            {Ihn, OutId} =
                case D of
                    forward -> {V1, V2};
                    _ -> {V2, V1}
                end,
            IhnV = get_var(Ihn, W),
            NewWS = strength_weakest(S, IhnV#var.walk_strength),
            W1 = set_var_field(OutId, walk_strength, NewWS, W),
            W2 = set_var_field(OutId, stay, IhnV#var.stay, W1),
            OutV = get_var(OutId, W2),
            case OutV#var.stay of
                true -> execute(get_con(con_id(C), W2), W2);
                false -> W2
            end;
        {scale_c, _Id, S, V1, V2, Sc, Of, D} ->
            {Ihn, OutId} =
                case D of
                    forward -> {V1, V2};
                    _ -> {V2, V1}
                end,
            IhnV = get_var(Ihn, W),
            NewWS = strength_weakest(S, IhnV#var.walk_strength),
            W1 = set_var_field(OutId, walk_strength, NewWS, W),
            ScV = get_var(Sc, W1),
            OfV = get_var(Of, W1),
            Stay = IhnV#var.stay andalso ScV#var.stay andalso OfV#var.stay,
            W2 = set_var_field(OutId, stay, Stay, W1),
            OutV = get_var(OutId, W2),
            case OutV#var.stay of
                true -> execute(get_con(con_id(C), W2), W2);
                false -> W2
            end
    end.

%% execute: returns updated world.
execute({stay_c, _, _, _, _}, W) -> W;
execute({edit_c, _, _, _, _}, W) -> W;
execute({eq_c, _, _, V1, V2, D}, W) ->
    case D of
        forward ->
            V1V = get_var(V1, W),
            set_var_field(V2, value, V1V#var.value, W);
        _ ->
            V2V = get_var(V2, W),
            set_var_field(V1, value, V2V#var.value, W)
    end;
execute({scale_c, _, _, V1, V2, Sc, Of, D}, W) ->
    V1V = get_var(V1, W),
    V2V = get_var(V2, W),
    ScV = get_var(Sc, W),
    OfV = get_var(Of, W),
    case D of
        forward ->
            Val = V1V#var.value * ScV#var.value + OfV#var.value,
            set_var_field(V2, value, Val, W);
        _ ->
            Val = (V2V#var.value - OfV#var.value) div ScV#var.value,
            set_var_field(V1, value, Val, W)
    end.

%%======================================================================
%% Constraint constructors (each runs add_constraint internally except
%% AbstractConstraint subclass that defers to subclass init)
%%======================================================================
new_stay(VarId, Strength, W) ->
    {Id, W1} = new_id(W),
    C = {stay_c, Id, Strength, VarId, false},
    W2 = put_con(C, W1),
    add_constraint(C, W2).

new_edit(VarId, Strength, W) ->
    {Id, W1} = new_id(W),
    C = {edit_c, Id, Strength, VarId, false},
    W2 = put_con(C, W1),
    {C, add_constraint(C, W2)}.

new_equality(V1, V2, Strength, W) ->
    {Id, W1} = new_id(W),
    C = {eq_c, Id, Strength, V1, V2, nil},
    W2 = put_con(C, W1),
    add_constraint(C, W2).

new_scale(Src, Sc, Of, Dst, Strength, W) ->
    {Id, W1} = new_id(W),
    C = {scale_c, Id, Strength, Src, Dst, Sc, Of, nil},
    W2 = put_con(C, W1),
    add_constraint(C, W2).

%%======================================================================
%% Planner operations
%%======================================================================
add_constraint(C, W0) ->
    W1 = add_to_graph(C, W0),
    incremental_add(C, W1).

incremental_add(C, W0) ->
    {Mark, W1} = new_mark(W0),
    {Overridden, W2} = satisfy(C, Mark, W1),
    incremental_add_loop(Overridden, Mark, W2).

incremental_add_loop(nil, _Mark, W) -> W;
incremental_add_loop(C, Mark, W0) ->
    {Overridden, W1} = satisfy(C, Mark, W0),
    incremental_add_loop(Overridden, Mark, W1).

%% satisfy: returns {Overridden | nil, World}
satisfy(C, Mark, W0) ->
    W1 = choose_method(C, Mark, W0),
    C1 = get_con(con_id(C), W1),
    case is_satisfied(C1) of
        true ->
            %% Mark every input
            Inputs = inputs_list(C1),
            W2 = lists:foldl(
                fun(Vid, WA) -> set_var_field(Vid, mark, Mark, WA) end,
                W1,
                Inputs
            ),
            OutId = output(C1),
            OutV = get_var(OutId, W2),
            Overridden = OutV#var.determined_by,
            W3 =
                case Overridden of
                    nil -> W2;
                    OvId ->
                        OvC = get_con(OvId, W2),
                        OvC1 = mark_unsatisfied(OvC),
                        put_con(OvC1, W2)
                end,
            W4 = set_var_field(OutId, determined_by, con_id(C1), W3),
            {Ok, W5} = add_propagate(C1, Mark, W4),
            case Ok of
                true ->
                    W6 = set_var_field(OutId, mark, Mark, W5),
                    OvFinal =
                        case Overridden of
                            nil -> nil;
                            OvId2 -> get_con(OvId2, W6)
                        end,
                    {OvFinal, W6};
                false ->
                    erlang:error(cycle_encountered)
            end;
        false ->
            case strength_same(con_strength(C1), ?STR_REQUIRED) of
                true -> erlang:error(failed_required);
                false -> {nil, W1}
            end
    end.

%% add_propagate: returns {bool, world}
add_propagate(C, Mark, W) ->
    Todo = [C],
    add_propagate_loop(Todo, C, Mark, W).

add_propagate_loop([], _Orig, _Mark, W) -> {true, W};
add_propagate_loop([D | Rest], Orig, Mark, W0) ->
    DId = con_id(D),
    Dcur = get_con(DId, W0),
    OutId = output(Dcur),
    OutV = get_var(OutId, W0),
    case OutV#var.mark =:= Mark of
        true ->
            W1 = incremental_remove(Orig, W0),
            {false, W1};
        false ->
            W1 = recalculate(Dcur, W0),
            DcurAfter = get_con(DId, W1),
            OutAfter = output(DcurAfter),
            More = constraints_consuming(OutAfter, W1),
            add_propagate_loop(Rest ++ More, Orig, Mark, W1)
    end.

incremental_remove(C, W0) ->
    OutId = output(C),
    Cur = get_con(con_id(C), W0),
    Cur1 = mark_unsatisfied(Cur),
    W1 = put_con(Cur1, W0),
    W2 = remove_from_graph(Cur1, W1),
    {Unsat, W3} = remove_propagate_from(OutId, W2),
    %% sort unsat by stronger
    UnsatSorted = lists:sort(
        fun(A, B) -> strength_stronger(con_strength(A), con_strength(B)) end,
        Unsat
    ),
    lists:foldl(fun(U, WA) -> incremental_add(U, WA) end, W3, UnsatSorted).

%% remove_propagate_from: returns {[constraint], world}
remove_propagate_from(OutVId, W0) ->
    W1 = set_var_field(OutVId, determined_by, nil, W0),
    W2 = set_var_field(OutVId, walk_strength, ?STR_ABS_WEAKEST, W1),
    W3 = set_var_field(OutVId, stay, true, W2),
    Todo = [OutVId],
    remove_prop_loop(Todo, [], W3).

remove_prop_loop([], Unsat, W) -> {Unsat, W};
remove_prop_loop([Vid | Rest], Unsat, W0) ->
    V = get_var(Vid, W0),
    %% append unsatisfied constraints
    Unsat1 = lists:foldl(
        fun(Cid, Acc) ->
            C = get_con(Cid, W0),
            case is_satisfied(C) of
                true -> Acc;
                false -> Acc ++ [C]
            end
        end,
        Unsat,
        V#var.constraints
    ),
    %% iterate constraints_consuming(v): each c except determined_by, satisfied
    Cons = constraints_consuming_for_var(Vid, W0),
    {NewTodo, W1} = lists:foldl(
        fun(C, {TAcc, WA}) ->
            WB = recalculate(C, WA),
            CAfter = get_con(con_id(C), WB),
            {TAcc ++ [output(CAfter)], WB}
        end,
        {[], W0},
        Cons
    ),
    remove_prop_loop(Rest ++ NewTodo, Unsat1, W1).

constraints_consuming_for_var(Vid, W) ->
    V = get_var(Vid, W),
    DC = V#var.determined_by,
    lists:filtermap(
        fun(Cid) ->
            C = get_con(Cid, W),
            case Cid =/= DC andalso is_satisfied(C) of
                true -> {true, C};
                false -> false
            end
        end,
        V#var.constraints
    ).

%% Returns constraints (list) consuming output of variable with id OutVId
constraints_consuming(OutVId, W) ->
    constraints_consuming_for_var(OutVId, W).

%%======================================================================
%% Plans
%%======================================================================
extract_plan_from_constraints(Cs, W) when is_list(Cs) ->
    %% Refetch from world: the records callers pass in may be stale.
    Sources = lists:filtermap(
        fun(C0) ->
            C = get_con(con_id(C0), W),
            case is_input(C) andalso is_satisfied(C) of
                true -> {true, C};
                false -> false
            end
        end,
        Cs
    ),
    make_plan(Sources, W).

make_plan(Sources, W0) ->
    {Mark, W1} = new_mark(W0),
    make_plan_loop(Sources, [], Mark, W1).

make_plan_loop([], Plan, _Mark, W) -> {Plan, W};
make_plan_loop([C | Rest], Plan, Mark, W0) ->
    OutId = output(C),
    OutV = get_var(OutId, W0),
    case OutV#var.mark =/= Mark andalso inputs_known(C, Mark, W0) of
        true ->
            Plan1 = Plan ++ [C],
            W1 = set_var_field(OutId, mark, Mark, W0),
            More = constraints_consuming(OutId, W1),
            make_plan_loop(Rest ++ More, Plan1, Mark, W1);
        false ->
            make_plan_loop(Rest, Plan, Mark, W0)
    end.

execute_plan(Plan, W) ->
    lists:foldl(
        fun(C, WA) ->
            CCur = get_con(con_id(C), WA),
            execute(CCur, WA)
        end,
        W,
        Plan
    ).

%%======================================================================
%% Planner: change_var, destroy_constraint
%%======================================================================
change_var(VarId, Val, W0) ->
    {EditC, W1} = new_edit(VarId, ?STR_PREFERRED, W0),
    {Plan, W2} = extract_plan_from_constraints([EditC], W1),
    W3 = lists:foldl(
        fun(_, WA) ->
            WB = set_var_field(VarId, value, Val, WA),
            execute_plan(Plan, WB)
        end,
        W2,
        lists:seq(1, 10)
    ),
    destroy_constraint(EditC, W3).

destroy_constraint(C, W0) ->
    Cur = get_con(con_id(C), W0),
    W1 =
        case is_satisfied(Cur) of
            true -> incremental_remove(Cur, W0);
            false -> W0
        end,
    Cur1 = get_con(con_id(C), W1),
    remove_from_graph(Cur1, W1).

%%======================================================================
%% Tests (chain_test + projection_test)
%%======================================================================
chain_test(N) ->
    W0 = new_world(),
    %% Create N+1 vars
    {VarIds, W1} = create_vars(N + 1, W0),
    %% Equality constraints v[i] -> v[i+1]
    W2 = add_chain_eqs(VarIds, W1),
    %% Stay on last
    Last = lists:last(VarIds),
    First = hd(VarIds),
    W3 = new_stay(Last, ?STR_STRONG_DEFAULT, W2),
    %% Edit on first
    {Edit, W4} = new_edit(First, ?STR_PREFERRED, W3),
    {Plan, W5} = extract_plan_from_constraints([Edit], W4),
    W6 = lists:foldl(
        fun(V, WA) ->
            WB = set_var_field(First, value, V, WA),
            WC = execute_plan(Plan, WB),
            LastV = get_var(Last, WC),
            case LastV#var.value =:= V of
                true -> WC;
                false -> erlang:error({chain_test_failed, V, LastV#var.value})
            end
        end,
        W5,
        lists:seq(1, 100)
    ),
    _W7 = destroy_constraint(Edit, W6),
    ok.

create_vars(0, W) -> {[], W};
create_vars(N, W0) ->
    {Id, W1} = new_var(W0),
    {Rest, W2} = create_vars(N - 1, W1),
    {[Id | Rest], W2}.

%% Pairwise walk over the chain — O(N) instead of O(N²) with lists:nth.
add_chain_eqs([_], W) -> W;
add_chain_eqs([V1, V2 | Rest], W0) ->
    W1 = new_equality(V1, V2, ?STR_REQUIRED, W0),
    add_chain_eqs([V2 | Rest], W1).

projection_test(N) ->
    W0 = new_world(),
    {Scale, W1} = new_var_with(10, W0),
    {Offset, W2} = new_var_with(1000, W1),
    {Dests, Src, Dst, W3} = create_proj_loop(1, N, [], nil, nil, Scale, Offset, W2),
    %% change_var(src, 17) -> dst.value == 1170
    W4 = change_var(Src, 17, W3),
    DstV1 = get_var(Dst, W4),
    case DstV1#var.value of
        1170 -> ok;
        Other1 -> erlang:error({projection_1_failed, Other1})
    end,
    %% change_var(dst, 1050) -> src.value == 5
    W5 = change_var(Dst, 1050, W4),
    SrcV1 = get_var(Src, W5),
    case SrcV1#var.value of
        5 -> ok;
        Other2 -> erlang:error({projection_2_failed, Other2})
    end,
    %% change_var(scale, 5) -> dests[i].value == (i+1)*5+1000 for 0..N-2
    W6 = change_var(Scale, 5, W5),
    DestsList = lists:reverse(Dests),
    check_dests(DestsList, 0, N - 1, fun(I) -> (I + 1) * 5 + 1000 end, projection_3_failed, W6),
    %% change_var(offset, 2000) -> dests[i].value == (i+1)*5+2000 for 0..N-2
    W7 = change_var(Offset, 2000, W6),
    check_dests(DestsList, 0, N - 1, fun(I) -> (I + 1) * 5 + 2000 end, projection_4_failed, W7),
    ok.

create_proj_loop(I, N, Dests, Src, Dst, _Scale, _Offset, W) when I > N -> {Dests, Src, Dst, W};
create_proj_loop(I, N, Dests, _SrcOld, _DstOld, Scale, Offset, W0) ->
    {Src, W1} = new_var_with(I, W0),
    {Dst, W2} = new_var_with(I, W1),
    Dests1 = [Dst | Dests],
    W3 = new_stay(Src, ?STR_DEFAULT, W2),
    W4 = new_scale(Src, Scale, Offset, Dst, ?STR_REQUIRED, W3),
    create_proj_loop(I + 1, N, Dests1, Src, Dst, Scale, Offset, W4).

%% Walk the dests list directly — O(N) instead of O(N²).
check_dests(_Dests, I, Stop, _ExpFun, _Tag, _W) when I >= Stop -> ok;
check_dests([Dst | Rest], I, Stop, ExpFun, Tag, W) ->
    DstV = get_var(Dst, W),
    Expected = ExpFun(I),
    case DstV#var.value of
        Expected -> check_dests(Rest, I + 1, Stop, ExpFun, Tag, W);
        Other -> erlang:error({Tag, I, Expected, Other})
    end.
