%% Havlak — translated from upstream/benchmarks/Ruby/havlak.rb.
%%
%% Loop recognition algorithm. Builds a control-flow graph, then finds
%% loops using a union-find based reducibility analysis. Verification:
%%
%%   inner_iter=1     -> [1605, 5213]
%%   inner_iter=15    -> [1647, 5213]
%%   inner_iter=150   -> [2052, 5213]
%%
%% The Ruby uses BasicBlock objects with mutable in_edges/out_edges,
%% a CFG with a Vector-indexed-by-name map, and parallel arrays
%% (header/type/last/nodes) in the loop finder. We thread all of that
%% through a state record. SOM Set/IdentitySet are realized as
%% identity-id sets (records have a unique :id for identity comparison).
-module(awfy_havlak).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, verify_result/2]).

%% Sentinels.
-define(UNVISITED, 2147483647).
-define(MAX_NON_BACK_PREDS, (32 * 1024)).

-record(bb, {name, in_edges = [], out_edges = []}).

-record(simple_loop, {
    id,
    is_reducible,
    is_root = false,
    nesting_level = 0,
    depth_level = 0,
    counter = 0,
    parent = nil,
    children = #{},      % set of loop ids
    basic_blocks = #{},  % set of BB names
    header
}).

-record(uf, {
    %% identity by id for O(1) hash/eq.
    id,
    %% bb name (or nil); the actual BB object lives in CFG state.
    bb = nil,
    dfs_number = 0,
    parent_id,           % id of parent uf node
    loop_id = nil
}).

-record(cfg, {
    start_node = nil,    % bb name
    basic_block_map = #{}, % name -> #bb{}
    %% kept in insertion order for deterministic iteration.
    bb_order = []
}).

-record(lsg, {
    loop_counter = 0,
    loops = [],          % loops in insertion order (newest last)
    loops_by_id = #{},
    root_id
}).

-record(hf, {
    cfg,
    lsg,
    non_back_preds = #{}, % w (int) -> set of int
    back_preds = #{},     % w (int) -> list of int
    number = #{},         % bb_name -> int
    max_size = 0,
    header,               % :array (size -> int)
    type,                 % :array (size -> atom)
    last,                 % :array (size -> int)
    nodes = #{},          % uf_id -> uf record
    nodes_by_w = #{}      % w (int) -> uf_id
}).

name() -> "Havlak".

inner_benchmark_loop(InnerIter) ->
    Result = run_loop_tester(InnerIter, 50, 10, 10, 5),
    verify_result(Result, InnerIter).

verify_result([R0, R1], 1) -> R0 =:= 1605 andalso R1 =:= 5213;
verify_result([R0, R1], 15) -> R0 =:= 1647 andalso R1 =:= 5213;
verify_result([R0, R1], 150) -> R0 =:= 2052 andalso R1 =:= 5213;
verify_result([R0, R1], 1500) -> R0 =:= 6102 andalso R1 =:= 5213;
verify_result([R0, R1], 15000) -> R0 =:= 46602 andalso R1 =:= 5213;
verify_result(_, _) -> false.

run_loop_tester(InnerIter, _Sz1, ParLoops, PparLoops, PpparLoops) ->
    Cfg0 = #cfg{},
    Cfg1 = create_node(0, Cfg0),
    Lsg0 = lsg_new(),

    %% construct_simple_cfg
    {Cfg2, _} = build_base_loop(0, Cfg1),
    Cfg3 = create_node(1, Cfg2),
    {Cfg4, _} = make_edge(0, 2, Cfg3),

    %% add_dummy_loops (InnerIter times)
    Lsg1 = add_dummy_loops(InnerIter, Cfg4, Lsg0),

    %% construct_cfg
    {Cfg5, _} = construct_cfg(Cfg4, ParLoops, PparLoops, PpparLoops),

    %% find_loops on the real lsg
    Lsg2 = find_loops_into(Cfg5, Lsg1),

    %% find_loop_iterations more times into fresh lsg's (results discarded)
    discard_loops(50, Cfg5),

    Lsg3 = calculate_nesting_level(Lsg2),
    [num_loops(Lsg3), num_nodes(Cfg5)].

%%======================================================================
%% CFG
%%======================================================================
create_node(Name, Cfg = #cfg{basic_block_map = M, bb_order = O}) ->
    case maps:is_key(Name, M) of
        true -> Cfg;
        false ->
            BB = #bb{name = Name},
            M1 = maps:put(Name, BB, M),
            Cfg1 = Cfg#cfg{basic_block_map = M1, bb_order = O ++ [Name]},
            case map_size(M1) of
                1 -> Cfg1#cfg{start_node = Name};
                _ -> Cfg1
            end
    end.

num_nodes(#cfg{basic_block_map = M}) -> map_size(M).

%% Add edge from From to To. Both must already exist; if not, create
%% them (Ruby's BasicBlockEdge calls cfg.create_node for both).
make_edge(From, To, Cfg0) ->
    Cfg1 = create_node(From, Cfg0),
    Cfg2 = create_node(To, Cfg1),
    BBFrom = maps:get(From, Cfg2#cfg.basic_block_map),
    BBTo = maps:get(To, Cfg2#cfg.basic_block_map),
    BBFrom1 = BBFrom#bb{out_edges = BBFrom#bb.out_edges ++ [To]},
    BBTo1 = BBTo#bb{in_edges = BBTo#bb.in_edges ++ [From]},
    M = maps:put(To, BBTo1, maps:put(From, BBFrom1, Cfg2#cfg.basic_block_map)),
    {Cfg2#cfg{basic_block_map = M}, ok}.

%%======================================================================
%% LoopTesterApp helpers (CFG construction)
%%======================================================================
build_diamond(Start, Cfg0) ->
    {Cfg1, _} = make_edge(Start, Start + 1, Cfg0),
    {Cfg2, _} = make_edge(Start, Start + 2, Cfg1),
    {Cfg3, _} = make_edge(Start + 1, Start + 3, Cfg2),
    {Cfg4, _} = make_edge(Start + 2, Start + 3, Cfg3),
    {Cfg4, Start + 3}.

build_straight(Start, N, Cfg0) ->
    Cfg1 = build_straight_loop(0, N, Start, Cfg0),
    {Cfg1, Start + N}.

build_straight_loop(I, N, _Start, Cfg) when I >= N -> Cfg;
build_straight_loop(I, N, Start, Cfg0) ->
    {Cfg1, _} = make_edge(Start + I, Start + I + 1, Cfg0),
    build_straight_loop(I + 1, N, Start, Cfg1).

build_base_loop(From, Cfg0) ->
    {Cfg1, Header} = build_straight(From, 1, Cfg0),
    {Cfg2, Diamond1} = build_diamond(Header, Cfg1),
    {Cfg3, D11} = build_straight(Diamond1, 1, Cfg2),
    {Cfg4, Diamond2} = build_diamond(D11, Cfg3),
    {Cfg5, Footer} = build_straight(Diamond2, 1, Cfg4),
    {Cfg6, _} = make_edge(Diamond2, D11, Cfg5),
    {Cfg7, _} = make_edge(Diamond1, Header, Cfg6),
    {Cfg8, _} = make_edge(Footer, From, Cfg7),
    build_straight(Footer, 1, Cfg8).

construct_cfg(Cfg0, ParLoops, PparLoops, PpparLoops) ->
    construct_cfg_par(0, ParLoops, PparLoops, PpparLoops, 2, Cfg0).

construct_cfg_par(I, Par, _Ppar, _Pppar, N, Cfg) when I >= Par -> {Cfg, N};
construct_cfg_par(I, Par, Ppar, Pppar, N, Cfg0) ->
    Cfg1 = create_node(N + 1, Cfg0),
    {Cfg2, _} = make_edge(2, N + 1, Cfg1),
    N2 = N + 1,
    {Cfg3, N3} = construct_cfg_ppar(0, Ppar, Pppar, N2, Cfg2),
    {Cfg4, _} = make_edge(N3, 1, Cfg3),
    construct_cfg_par(I + 1, Par, Ppar, Pppar, N3, Cfg4).

construct_cfg_ppar(I, Ppar, _Pppar, N, Cfg) when I >= Ppar -> {Cfg, N};
construct_cfg_ppar(I, Ppar, Pppar, N, Cfg0) ->
    Top = N,
    {Cfg1, N1} = build_straight(N, 1, Cfg0),
    {Cfg2, N2} = construct_cfg_pppar(0, Pppar, N1, Cfg1),
    {Cfg3, Bottom} = build_straight(N2, 1, Cfg2),
    {Cfg4, _} = make_edge(N2, Top, Cfg3),
    construct_cfg_ppar(I + 1, Ppar, Pppar, Bottom, Cfg4).

construct_cfg_pppar(I, Pppar, N, Cfg) when I >= Pppar -> {Cfg, N};
construct_cfg_pppar(I, Pppar, N, Cfg0) ->
    {Cfg1, N1} = build_base_loop(N, Cfg0),
    construct_cfg_pppar(I + 1, Pppar, N1, Cfg1).

%%======================================================================
%% LoopStructureGraph
%%======================================================================
lsg_new() ->
    Root = #simple_loop{
        id = 0,
        is_reducible = true,
        nesting_level = 0,
        depth_level = 0,
        counter = 0
    },
    %% set_nesting_level(0) sets is_root via set_is_root.
    Root1 = Root#simple_loop{is_root = true},
    #lsg{
        loop_counter = 1,
        loops = [Root1],
        loops_by_id = #{0 => Root1},
        root_id = 0
    }.

create_new_loop(Bb, IsReducible, Lsg = #lsg{loop_counter = C, loops = Ls, loops_by_id = M}) ->
    Loop = #simple_loop{
        id = C,
        is_reducible = IsReducible,
        counter = C,
        header = Bb,
        basic_blocks =
            case Bb of
                undefined -> #{};
                _ -> #{Bb => true}
            end
    },
    {Loop, Lsg#lsg{
        loop_counter = C + 1,
        loops = [Loop | Ls],
        loops_by_id = maps:put(C, Loop, M)
    }}.

put_loop(Loop = #simple_loop{id = Id}, Lsg) ->
    Lsg#lsg{loops_by_id = maps:put(Id, Loop, Lsg#lsg.loops_by_id)}.

num_loops(#lsg{loops_by_id = M}) -> map_size(M).

calculate_nesting_level(Lsg) ->
    %% Set parent to root for any loop without one (except root itself).
    RootId = Lsg#lsg.root_id,
    Lsg1 = lists:foldl(
        fun(#simple_loop{id = Id, is_root = IsRoot, parent = Parent}, Acc) when not IsRoot, Parent =:= nil ->
                set_parent(Id, RootId, Acc);
            (_, Acc) ->
                Acc
        end,
        Lsg,
        maps:values(Lsg#lsg.loops_by_id)
    ),
    calc_nest_rec(RootId, 0, Lsg1).

calc_nest_rec(LoopId, Depth, Lsg) ->
    Loop0 = maps:get(LoopId, Lsg#lsg.loops_by_id),
    Loop1 = Loop0#simple_loop{depth_level = Depth},
    Lsg1 = put_loop(Loop1, Lsg),
    Children = maps:keys(Loop1#simple_loop.children),
    {Lsg2, MaxNL} = lists:foldl(
        fun(ChId, {LsgA, MaxNLA}) ->
            LsgB = calc_nest_rec(ChId, Depth + 1, LsgA),
            ChLoop = maps:get(ChId, LsgB#lsg.loops_by_id),
            {LsgB, max(MaxNLA, 1 + ChLoop#simple_loop.nesting_level)}
        end,
        {Lsg1, 0},
        Children
    ),
    Loop2 = maps:get(LoopId, Lsg2#lsg.loops_by_id),
    Loop3 = Loop2#simple_loop{nesting_level = MaxNL, is_root = (MaxNL =:= 0)},
    put_loop(Loop3, Lsg2).

set_parent(ChildId, ParentId, Lsg) ->
    Child0 = maps:get(ChildId, Lsg#lsg.loops_by_id),
    Child1 = Child0#simple_loop{parent = ParentId},
    Parent0 = maps:get(ParentId, Lsg#lsg.loops_by_id),
    Parent1 = Parent0#simple_loop{
        children = maps:put(ChildId, true, Parent0#simple_loop.children)
    },
    M1 = maps:put(ChildId, Child1, Lsg#lsg.loops_by_id),
    M2 = maps:put(ParentId, Parent1, M1),
    Lsg#lsg{loops_by_id = M2}.

%%======================================================================
%% Loop finder
%%======================================================================
add_dummy_loops(0, _Cfg, Lsg) -> Lsg;
add_dummy_loops(N, Cfg, Lsg) ->
    Lsg1 = find_loops_into(Cfg, Lsg),
    add_dummy_loops(N - 1, Cfg, Lsg1).

discard_loops(0, _Cfg) -> ok;
discard_loops(N, Cfg) ->
    _ = find_loops_into(Cfg, lsg_new()),
    discard_loops(N - 1, Cfg).

find_loops_into(Cfg, Lsg) ->
    case Cfg#cfg.start_node of
        nil ->
            Lsg;
        _ ->
            HF0 = #hf{cfg = Cfg, lsg = Lsg},
            HF1 = find_loops(HF0),
            HF1#hf.lsg
    end.

find_loops(HF0) ->
    Cfg = HF0#hf.cfg,
    Size = num_nodes(Cfg),
    HF1 = HF0#hf{
        non_back_preds = #{},
        back_preds = #{},
        number = #{}
    },
    HF2 =
        case Size > HF1#hf.max_size of
            true ->
                HF1#hf{
                    header = array:new(Size, [{default, 0}]),
                    type = array:new(Size, [{default, 'BB_NONHEADER'}]),
                    last = array:new(Size, [{default, 0}]),
                    max_size = Size
                };
            false ->
                HF1
        end,
    HF3 = init_size_arrays(0, Size, HF2),
    HF4 = init_all_nodes(HF3),
    HF5 = identify_edges(0, Size, HF4),
    HF6 = HF5#hf{header = array:set(0, 0, HF5#hf.header)},
    HF7 = main_loop(Size - 1, HF6),
    HF7.

init_size_arrays(I, Size, HF) when I >= Size -> HF;
init_size_arrays(I, Size, HF) ->
    %% Initialize per-w state.
    NBP1 = maps:put(I, sets:new([{version, 2}]), HF#hf.non_back_preds),
    BP1 = maps:put(I, [], HF#hf.back_preds),
    %% Allocate a UnionFindNode for index I.
    UfId = I,
    Uf = #uf{id = UfId, parent_id = UfId},
    Nodes1 = maps:put(UfId, Uf, HF#hf.nodes),
    NodesByW1 = maps:put(I, UfId, HF#hf.nodes_by_w),
    init_size_arrays(I + 1, Size, HF#hf{
        non_back_preds = NBP1,
        back_preds = BP1,
        nodes = Nodes1,
        nodes_by_w = NodesByW1
    }).

init_all_nodes(HF) ->
    %% Set @number[bb] = UNVISITED for every bb in CFG.
    Number0 = lists:foldl(
        fun(Name, Acc) -> maps:put(Name, ?UNVISITED, Acc) end,
        HF#hf.number,
        HF#hf.cfg#cfg.bb_order
    ),
    HF1 = HF#hf{number = Number0},
    Start = HF1#hf.cfg#cfg.start_node,
    {_, HF2} = do_dfs(Start, 0, HF1),
    HF2.

do_dfs(BbName, Current, HF0) ->
    %% nodes[Current].init_node(bb, dfs_number)
    UfId = maps:get(Current, HF0#hf.nodes_by_w),
    Uf0 = maps:get(UfId, HF0#hf.nodes),
    Uf1 = Uf0#uf{parent_id = UfId, bb = BbName, dfs_number = Current, loop_id = nil},
    HF1 = HF0#hf{nodes = maps:put(UfId, Uf1, HF0#hf.nodes)},
    HF2 = HF1#hf{number = maps:put(BbName, Current, HF1#hf.number)},
    BB = maps:get(BbName, HF2#hf.cfg#cfg.basic_block_map),
    {LastId, HF3} = lists:foldl(
        fun(Target, {LastIdA, HFA}) ->
            case maps:get(Target, HFA#hf.number) of
                ?UNVISITED ->
                    do_dfs(Target, LastIdA + 1, HFA);
                _ ->
                    {LastIdA, HFA}
            end
        end,
        {Current, HF2},
        BB#bb.out_edges
    ),
    HF4 = HF3#hf{last = array:set(Current, LastId, HF3#hf.last)},
    {LastId, HF4}.

identify_edges(W, Size, HF) when W >= Size -> HF;
identify_edges(W, Size, HF0) ->
    HF1 = HF0#hf{
        header = array:set(W, 0, HF0#hf.header),
        type = array:set(W, 'BB_NONHEADER', HF0#hf.type)
    },
    UfId = maps:get(W, HF1#hf.nodes_by_w),
    Uf = maps:get(UfId, HF1#hf.nodes),
    HF2 =
        case Uf#uf.bb of
            nil ->
                HF1#hf{type = array:set(W, 'BB_DEAD', HF1#hf.type)};
            BbName ->
                process_edges(BbName, W, HF1)
        end,
    identify_edges(W + 1, Size, HF2).

process_edges(BbName, W, HF) ->
    BB = maps:get(BbName, HF#hf.cfg#cfg.basic_block_map),
    case length(BB#bb.in_edges) of
        0 -> HF;
        _ ->
            lists:foldl(
                fun(NodeV, HFA) ->
                    V = maps:get(NodeV, HFA#hf.number),
                    case V of
                        ?UNVISITED -> HFA;
                        _ ->
                            case is_ancestor(W, V, HFA) of
                                true ->
                                    BPW = maps:get(W, HFA#hf.back_preds),
                                    HFA#hf{back_preds = maps:put(W, BPW ++ [V], HFA#hf.back_preds)};
                                false ->
                                    NBPW = maps:get(W, HFA#hf.non_back_preds),
                                    HFA#hf{non_back_preds = maps:put(W, sets:add_element(V, NBPW), HFA#hf.non_back_preds)}
                            end
                    end
                end,
                HF,
                BB#bb.in_edges
            )
    end.

is_ancestor(W, V, HF) ->
    W =< V andalso V =< array:get(W, HF#hf.last).

main_loop(W, HF) when W < 0 -> HF;
main_loop(W, HF0) ->
    UfId = maps:get(W, HF0#hf.nodes_by_w),
    Uf = maps:get(UfId, HF0#hf.nodes),
    HF1 =
        case Uf#uf.bb of
            nil ->
                %% no node — still need to potentially create loop based on type
                HF0;
            _ ->
                process_w(W, HF0)
        end,
    main_loop(W - 1, HF1).

process_w(W, HF0) ->
    {NodePool0, HF1} = step_d(W, [], HF0),
    WorkList0 = NodePool0,
    HF2 =
        case length(NodePool0) of
            0 -> HF1;
            _ -> HF1#hf{type = array:set(W, 'BB_REDUCIBLE', HF1#hf.type)}
        end,
    {NodePool1, HF3} = drain_worklist(W, NodePool0, WorkList0, HF2),
    UfWId = maps:get(W, HF3#hf.nodes_by_w),
    UfW = maps:get(UfWId, HF3#hf.nodes),
    case length(NodePool1) > 0 orelse array:get(W, HF3#hf.type) =:= 'BB_SELF' of
        true ->
            {Loop, Lsg1} = create_new_loop(
                UfW#uf.bb,
                array:get(W, HF3#hf.type) =/= 'BB_IRREDUCIBLE',
                HF3#hf.lsg
            ),
            HF4 = HF3#hf{lsg = Lsg1},
            set_loop_attrs(W, NodePool1, Loop, HF4);
        false ->
            HF3
    end.

drain_worklist(_W, NodePool, [], HF) -> {NodePool, HF};
drain_worklist(W, NodePool0, [X | Rest], HF0) ->
    NonBackSize = sets:size(maps:get(X#uf.dfs_number, HF0#hf.non_back_preds)),
    case NonBackSize > ?MAX_NON_BACK_PREDS of
        true ->
            %% bail out — return current state
            {NodePool0, HF0};
        false ->
            {NodePool1, NewWork, HF1} = step_e(W, X, NodePool0, HF0),
            drain_worklist(W, NodePool1, Rest ++ NewWork, HF1)
    end.

step_e(W, X, NodePool0, HF0) ->
    NbpSet = maps:get(X#uf.dfs_number, HF0#hf.non_back_preds),
    Iter = sets:to_list(NbpSet),
    lists:foldl(
        fun(I, {NP, NW, HFA}) ->
            YId = maps:get(I, HFA#hf.nodes_by_w),
            {YDash, HFB} = find_set(YId, HFA),
            case is_ancestor(W, YDash#uf.dfs_number, HFB) of
                false ->
                    HFC = HFB#hf{
                        type = array:set(W, 'BB_IRREDUCIBLE', HFB#hf.type),
                        non_back_preds = maps:put(
                            W,
                            sets:add_element(YDash#uf.dfs_number, maps:get(W, HFB#hf.non_back_preds)),
                            HFB#hf.non_back_preds
                        )
                    },
                    {NP, NW, HFC};
                true ->
                    case YDash#uf.dfs_number =/= W of
                        true ->
                            case lists:any(fun(N) -> N#uf.id =:= YDash#uf.id end, NP) of
                                true ->
                                    {NP, NW, HFB};
                                false ->
                                    {NP ++ [YDash], NW ++ [YDash], HFB}
                            end;
                        false ->
                            {NP, NW, HFB}
                    end
            end
        end,
        {NodePool0, [], HF0},
        Iter
    ).

step_d(W, NodePool, HF) ->
    BPs = maps:get(W, HF#hf.back_preds),
    lists:foldl(
        fun(V, {NP, HFA}) ->
            case V =/= W of
                true ->
                    UfVId = maps:get(V, HFA#hf.nodes_by_w),
                    {Found, HFB} = find_set(UfVId, HFA),
                    {NP ++ [Found], HFB};
                false ->
                    {NP, HFA#hf{type = array:set(W, 'BB_SELF', HFA#hf.type)}}
            end
        end,
        {NodePool, HF},
        BPs
    ).

%% Iterative path-compression find_set on the union-find structure.
find_set(NodeId, HF) ->
    Node = maps:get(NodeId, HF#hf.nodes),
    {Path, Root, HF1} = climb(Node, [], HF),
    %% Path-compress: every node in Path gets parent_id := Root.id
    HF2 = lists:foldl(
        fun(N, HFA) ->
            N1 = N#uf{parent_id = Node#uf.parent_id},
            HFA#hf{nodes = maps:put(N1#uf.id, N1, HFA#hf.nodes)}
        end,
        HF1,
        Path
    ),
    {Root, HF2}.

climb(Node, Path, HF) ->
    case Node#uf.parent_id =:= Node#uf.id of
        true ->
            {Path, Node, HF};
        false ->
            Parent = maps:get(Node#uf.parent_id, HF#hf.nodes),
            %% append iff not already-compressed.
            Path1 =
                case Parent#uf.parent_id =/= Parent#uf.id of
                    true -> Path ++ [Node];
                    false -> Path
                end,
            climb(Parent, Path1, HF)
    end.

set_loop_attrs(W, NodePool, Loop, HF) ->
    UfWId = maps:get(W, HF#hf.nodes_by_w),
    UfW0 = maps:get(UfWId, HF#hf.nodes),
    UfW1 = UfW0#uf{loop_id = Loop#simple_loop.id},
    HF1 = HF#hf{nodes = maps:put(UfWId, UfW1, HF#hf.nodes)},
    lists:foldl(
        fun(Node, HFA) ->
            DFS = Node#uf.dfs_number,
            HFA1 = HFA#hf{header = array:set(DFS, W, HFA#hf.header)},
            %% node.union(@nodes[w])
            Node1 = (maps:get(Node#uf.id, HFA1#hf.nodes))#uf{parent_id = UfWId},
            HFA2 = HFA1#hf{nodes = maps:put(Node1#uf.id, Node1, HFA1#hf.nodes)},
            case Node1#uf.loop_id of
                nil ->
                    Loop1 = (maps:get(Loop#simple_loop.id, HFA2#hf.lsg#lsg.loops_by_id))#simple_loop{
                        basic_blocks = maps:put(Node1#uf.bb, true, (maps:get(Loop#simple_loop.id, HFA2#hf.lsg#lsg.loops_by_id))#simple_loop.basic_blocks)
                    },
                    HFA2#hf{lsg = put_loop(Loop1, HFA2#hf.lsg)};
                ChildId ->
                    Lsg1 = set_parent(ChildId, Loop#simple_loop.id, HFA2#hf.lsg),
                    HFA2#hf{lsg = Lsg1}
            end
        end,
        HF1,
        NodePool
    ).
