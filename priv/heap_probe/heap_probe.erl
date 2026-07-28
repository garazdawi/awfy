%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: Apache-2.0
-module(heap_probe).
-moduledoc("""
P-A read-only heap/term-behaviour profiler for idea #75 Stage 0.

Zero VM patch: everything here rides `erlang:trace/3`, `sys:replace_state/3`,
and the `erts_debug` size primitives on a stock OTP node, so it can be
dropped into (or distribution-attached to) any running system.

Two measurement paths, because the two questions need different vantage
points:

  * `send_census/2` — trace `send` events and bucket every message by flat
    copy size, by destination fan-out multiplicity (identical `phash2`
    payloads to N distinct pids within a window), and (optionally) by
    whether the sender is *forwarding* a term it just received (multi-hop).
    This measures the COPY VOLUME and SHAPE. It CANNOT measure how much
    sharing the copy destroys: the traced message is itself a flattened
    copy, so `size_shared` on it always equals `flat_size`. Use the next
    function for that.

  * `sharing_sample/2` — for `sys`-compliant processes (gen_server /
    gen_statem / gen_event), run `erts_debug:size_shared/1` vs `flat_size/1`
    INSIDE the owning process via `sys:replace_state/3` (identity state
    function) and side-channel the integers out. This is the only read-only
    way to see the sharing a send-copy would destroy without the P-B
    send-path counter.

Plus `gc_census/2` (promotion/survivor counters via garbage_collection
trace) and `demand_proxies/0` (whole-node binary / persistent_term / memory).
""").

-export([send_census/1, send_census/2,
         gc_census/1, gc_census/2,
         sharing_sample/1, sharing_sample/2,
         demand_proxies/0,
         format/1, print/1]).

%% flat-size class edges, in WORDS (6 buckets)
-define(SIZE_EDGES, [8, 64, 512, 4096, 32768]).
%% destroyed/flat ratio class edges (5 buckets)
-define(RATIO_EDGES, [0.01, 0.10, 0.50, 0.90]).
%% fan-out multiplicity class edges (5 buckets: 1, 2-4, 5-16, 17-64, 65+)
-define(FAN_EDGES, [1, 4, 16, 64]).

%%======================================================================
%% Send-shape census (copy volume + shape; NOT sharing — see module doc)
%%======================================================================
-spec send_census(map()) -> map().
send_census(Opts) when is_map(Opts) ->
    send_census(maps:get(targets, Opts, existing), Opts).

-spec send_census(term(), map()) -> map().
send_census(Targets, Opts) ->
    run_collector(fun send_collector/3, Targets, Opts).

send_collector(Parent, Targets, Opts) ->
    Self = self(),
    Atoms = [send | case maps:get(multihop, Opts, false) of
                        true -> ['receive']; false -> [] end],
    Matched = enable(Targets, Atoms ++ [{tracer, Self}]),
    _ = t(Self, false, Atoms),                    % never trace the collector
    _ = erlang:send_after(maps:get(duration, Opts, 5000), Self, stop),
    Acc = loop_send(fresh_send_acc(), Opts),
    disable(Targets, Atoms),
    Parent ! {census_result, finalize_send(Acc, Matched, maps:get(duration, Opts, 5000))}.

fresh_send_acc() ->
    #{n => 0, flat => 0, size => #{}, fan => #{}, fan_entries => 0,
      fanhist => #{}, recv => #{}, multihop => 0, srcfan => #{}}.

loop_send(Acc, Opts) ->
    receive
        stop -> Acc;
        {trace, From, send, Msg, To} ->
            loop_send(on_send(Acc, From, Msg, To, Opts), Opts);
        {trace, From, send_to_non_existing_process, Msg, To} ->
            loop_send(on_send(Acc, From, Msg, To, Opts), Opts);
        {trace, Pid, 'receive', Msg} ->
            loop_send(on_recv(Acc, Pid, Msg), Opts);
        _Other ->
            loop_send(Acc, Opts)
    end.

on_send(Acc0, From, Msg, To, Opts) ->
    Flat = flat_size(Msg),
    FP = erlang:phash2(Msg),
    Acc1 = bump_totals(Acc0, Flat),
    Acc2 = bump_hist_size(Acc1, Flat),
    Acc3 = bump_fanout(Acc2, FP, To, Opts),
    Acc4 = bump_srcfan(Acc3, From, To),
    maybe_multihop(Acc4, From, FP, Opts).

%% distinct destinations reached by each sending process (a payload-identity-
%% independent fan-out signal: a channel delivering to N queues shows N here
%% even when each hop re-wraps the message with a distinct envelope).
bump_srcfan(A = #{srcfan := SF}, From, To) ->
    D = maps:get(From, SF, #{}),
    A#{srcfan := SF#{From => D#{To => true}}}.

on_recv(Acc = #{recv := Recv}, Pid, Msg) ->
    FP = erlang:phash2(Msg),
    Acc#{recv := Recv#{Pid => bounded_put(maps:get(Pid, Recv, #{}), FP, 64)}}.

bump_totals(A = #{n := N, flat := F}, Flat) -> A#{n := N + 1, flat := F + Flat}.

bump_hist_size(A = #{size := H}, Flat) ->
    B = ibucket(Flat, ?SIZE_EDGES),
    {C, FW} = maps:get(B, H, {0, 0}),
    A#{size := H#{B => {C + 1, FW + Flat}}}.

bump_fanout(A = #{fan := Fan, fan_entries := FE}, FP, To, Opts) ->
    New = not maps:is_key(FP, Fan),
    Dests = maps:get(FP, Fan, #{}),
    A1 = A#{fan := Fan#{FP => Dests#{To => true}},
            fan_entries := FE + (case New of true -> 1; false -> 0 end)},
    case maps:get(fan_entries, A1) >= maps:get(fanout_cap, Opts, 50000) of
        true -> flush_fanout(A1);
        false -> A1
    end.

flush_fanout(A = #{fan := Fan, fanhist := FH}) ->
    FH1 = maps:fold(
            fun(_FP, Dests, Acc) ->
                    B = ibucket(maps:size(Dests), ?FAN_EDGES),
                    Acc#{B => maps:get(B, Acc, 0) + 1}
            end, FH, Fan),
    A#{fan := #{}, fan_entries := 0, fanhist := FH1}.

maybe_multihop(A = #{recv := Recv, multihop := MH}, From, FP, Opts) ->
    case maps:get(multihop, Opts, false)
        andalso maps:is_key(FP, maps:get(From, Recv, #{})) of
        true -> A#{multihop := MH + 1};
        false -> A
    end.

finalize_send(Acc0, Matched, Duration) ->
    #{n := N, flat := F, size := Size, fanhist := FH, multihop := MH,
      srcfan := SF} = flush_fanout(Acc0),
    SenderFanHist = maps:fold(
                      fun(_From, Dests, H) ->
                              B = ibucket(maps:size(Dests), ?FAN_EDGES),
                              H#{B => maps:get(B, H, 0) + 1}
                      end, #{}, SF),
    WS = erlang:system_info(wordsize),
    #{census => send_shape,
      traced_procs => Matched,
      duration_ms => Duration,
      sends => N,
      send_rate_per_s => rate(N, Duration),
      copied_bytes => F * WS,
      copy_rate_bytes_per_s => rate(F * WS, Duration),
      bytes_per_send => case N of 0 -> 0; _ -> (F * WS) div N end,
      by_size_class => label_size(Size, WS),
      by_payload_fanout => label_fanout(FH),
      by_sender_fanout => label_fanout(SenderFanHist),
      multihop_sends => MH,
      multihop_frac => frac(MH, N),
      note => <<"sharing-destroyed is NOT here (trace copies are flattened); "
                "use sharing_sample/2 for the owner-context ratio">>}.

%%======================================================================
%% Owner-context sharing sample (flat vs shared, measured IN the process)
%%======================================================================
-spec sharing_sample([pid()|atom()]) -> map().
sharing_sample(Procs) -> sharing_sample(Procs, #{}).

-spec sharing_sample([pid()|atom()], map()) -> map().
sharing_sample(Procs, Opts) ->
    Timeout = maps:get(sample_timeout, Opts, 200),
    Pairs = [P || Proc <- Procs, {ok, _, _} = P <- [sample_one(Proc, Timeout)]],
    finalize_sharing(Pairs, length(Procs)).

sample_one(Proc, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    F = fun(S) ->
                Self ! {Ref, flat_size(S), shared_size(S)},
                S
        end,
    try
        _ = sys:replace_state(Proc, F, Timeout),
        receive {Ref, Fl, Sh} -> {ok, Fl, Sh} after Timeout -> skip end
    catch _:_ -> skip
    end.

finalize_sharing(Pairs, Asked) ->
    WS = erlang:system_info(wordsize),
    {SF, SS, Hist} =
        lists:foldl(
          fun({ok, F, S}, {AF, AS, H}) ->
                  R = case F of 0 -> 0.0; _ -> (F - S) / F end,
                  B = fbucket(R, ?RATIO_EDGES),
                  {AF + F, AS + S, H#{B => maps:get(B, H, 0) + 1}}
          end, {0, 0, #{}}, Pairs),
    Destroyed = max(0, SF - SS),
    #{census => sharing_sample,
      procs_asked => Asked,
      procs_measured => length(Pairs),
      flat_bytes => SF * WS,
      shared_bytes => SS * WS,
      destroyed_bytes => Destroyed * WS,
      sharing_destroyed_frac => frac(Destroyed, SF),
      by_sharing_ratio => label_ratio(Hist)}.

%%======================================================================
%% GC / promotion census
%%======================================================================
-spec gc_census(map()) -> map().
gc_census(Opts) when is_map(Opts) ->
    gc_census(maps:get(targets, Opts, existing), Opts).

-spec gc_census(term(), map()) -> map().
gc_census(Targets, Opts) ->
    run_collector(fun gc_collector/3, Targets, Opts).

gc_collector(Parent, Targets, Opts) ->
    Self = self(),
    Matched = enable(Targets, [garbage_collection, {tracer, Self}]),
    _ = t(Self, false, [garbage_collection]),
    _ = erlang:send_after(maps:get(duration, Opts, 5000), Self, stop),
    Acc = loop_gc(#{last => #{}, promoted => 0, minors => 0, majors => 0,
                    heap_sum => 0, ends => 0}, Opts),
    disable(Targets, [garbage_collection]),
    Parent ! {census_result, finalize_gc(Acc, Matched, maps:get(duration, Opts, 5000))}.

loop_gc(A, Opts) ->
    receive
        stop -> A;
        {trace, Pid, gc_minor_end, Info} -> loop_gc(on_gc(A, Pid, Info, minor), Opts);
        {trace, Pid, gc_major_end, Info} -> loop_gc(on_gc(A, Pid, Info, major), Opts);
        _ -> loop_gc(A, Opts)
    end.

on_gc(A = #{last := L, promoted := P, minors := Mi, majors := Ma,
            heap_sum := HS, ends := E}, Pid, Info, Kind) ->
    Old = pl(old_heap_size, Info),
    Delta = max(0, Old - maps:get(Pid, L, 0)),
    {Mi1, Ma1} = case Kind of minor -> {Mi + 1, Ma}; major -> {Mi, Ma + 1} end,
    A#{last := L#{Pid => Old}, promoted := P + Delta,
       minors := Mi1, majors := Ma1, heap_sum := HS + pl(heap_size, Info),
       ends := E + 1}.

finalize_gc(#{promoted := P, minors := Mi, majors := Ma, heap_sum := HS,
              ends := E}, Matched, Duration) ->
    WS = erlang:system_info(wordsize),
    #{census => gc_promotion,
      traced_procs => Matched,
      duration_ms => Duration,
      minor_gcs => Mi,
      major_gcs => Ma,
      promoted_bytes => P * WS,
      promotion_rate_bytes_per_s => rate(P * WS, Duration),
      avg_young_heap_bytes_after_gc =>
          case E of 0 -> 0; _ -> (HS * WS) div E end}.

%%======================================================================
%% Demand proxies (instantaneous, whole-node)
%%======================================================================
-spec demand_proxies() -> map().
demand_proxies() ->
    PT = try persistent_term:info() catch _:_ -> #{} end,
    #{census => demand_proxies,
      binary_bytes => erlang:memory(binary),
      processes_bytes => erlang:memory(processes),
      ets_bytes => erlang:memory(ets),
      total_bytes => erlang:memory(total),
      process_count => erlang:system_info(process_count),
      persistent_term => PT}.

%%======================================================================
%% Shared plumbing
%%======================================================================
run_collector(Fun, Targets, Opts) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Fun(Parent, Targets, Opts) end),
    receive
        {census_result, R} -> demonitor(Ref, [flush]), R;
        {'DOWN', Ref, process, Pid, Reason} -> {error, {collector_died, Reason}}
    end.

enable(all, Flags)      -> erlang:trace(all, true, Flags);
enable(existing, Flags) -> erlang:trace(existing, true, Flags);
enable(new, Flags)      -> erlang:trace(new, true, Flags);
enable({sample, N}, Flags) ->
    lists:sum([t(P, true, Flags) || P <- sample_procs(N)]);
enable(Pids, Flags) when is_list(Pids) ->
    lists:sum([t(P, true, Flags) || P <- Pids]).

disable(all, Fl)         -> _ = t(all, false, Fl), ok;
disable(existing, Fl)    -> _ = t(all, false, Fl), ok;
disable(new, Fl)         -> _ = t(new, false, Fl), ok;
disable({sample, _}, Fl) -> _ = t(all, false, Fl), ok;
disable(Pids, Fl) when is_list(Pids) ->
    _ = [t(P, false, Fl) || P <- Pids], ok.

t(A, B, C) -> try erlang:trace(A, B, C) catch _:_ -> 0 end.

sample_procs(N) ->
    Ps = erlang:processes() -- [self()],
    lists:sublist([P || {_, P} <- lists:sort([{erlang:phash2(X), X} || X <- Ps])], N).

bounded_put(Set, K, Max) ->
    S = Set#{K => true},
    case maps:size(S) > Max of
        true -> maps:remove(hd(maps:keys(S)), S);
        false -> S
    end.

flat_size(T) -> try erts_debug:flat_size(T) catch _:_ -> erts_debug:size(T) end.
shared_size(T) -> try erts_debug:size_shared(T) catch _:_ -> flat_size(T) end.

pl(K, L) -> proplists:get_value(K, L, 0).
rate(_, 0) -> 0.0;
rate(N, Ms) -> N * 1000 / Ms.
frac(_, 0) -> 0.0;
frac(A, B) -> A / B.

ibucket(V, Edges) -> ibucket(V, Edges, 0).
ibucket(_, [], I) -> I;
ibucket(V, [E | _], I) when V =< E -> I;
ibucket(V, [_ | R], I) -> ibucket(V, R, I + 1).

fbucket(V, Edges) -> fbucket(V, Edges, 0).
fbucket(_, [], I) -> I;
fbucket(V, [E | _], I) when V < E -> I;
fbucket(V, [_ | R], I) -> fbucket(V, R, I + 1).

%%======================================================================
%% Labels + formatting
%%======================================================================
label_size(H, WS) ->
    Names = ["<=8w", "9-64w", "65-512w", "513-4Kw", "4K-32Kw", ">32Kw"],
    maps:from_list(
      [{L, #{sends => C, copied_bytes => FW * WS}}
       || {I, L} <- lists:zip(lists:seq(0, 5), Names),
          {C, FW} <- [maps:get(I, H, {0, 0})], C > 0]).

label_ratio(H) ->
    Names = ["<0.01", "0.01-0.10", "0.10-0.50", "0.50-0.90", ">=0.90"],
    maps:from_list(
      [{L, maps:get(I, H, 0)}
       || {I, L} <- lists:zip(lists:seq(0, 4), Names), maps:get(I, H, 0) > 0]).

label_fanout(H) ->
    Names = ["1", "2-4", "5-16", "17-64", "65+"],
    maps:from_list(
      [{L, maps:get(I, H, 0)}
       || {I, L} <- lists:zip(lists:seq(0, 4), Names), maps:get(I, H, 0) > 0]).

-spec print(map()) -> ok.
print(Census) -> io:format("~s~n", [format(Census)]).

-spec format(map()) -> iolist().
format(M) when is_map(M) ->
    Keys = [census, traced_procs, duration_ms, sends, send_rate_per_s,
            copied_bytes, copy_rate_bytes_per_s, bytes_per_send,
            multihop_sends, multihop_frac,
            procs_asked, procs_measured, flat_bytes, shared_bytes,
            destroyed_bytes, sharing_destroyed_frac,
            minor_gcs, major_gcs, promoted_bytes, promotion_rate_bytes_per_s,
            avg_young_heap_bytes_after_gc,
            by_size_class, by_sharing_ratio, by_payload_fanout, by_sender_fanout,
            binary_bytes, processes_bytes, ets_bytes, total_bytes,
            process_count, persistent_term, note],
    [[pad(K), fmt_val(maps:get(K, M)), $\n] || K <- Keys, maps:is_key(K, M)];
format(Other) -> io_lib:format("~p", [Other]).

pad(K) -> io_lib:format("~-28s", [atom_to_list(K)]).
fmt_val(V) when is_map(V) ->
    [$\n | [["    ", io_lib:format("~-14s", [to_s(K)]),
            io_lib:format("~p", [Val]), $\n] || K := Val <- V]];
fmt_val(V) when is_float(V) -> io_lib:format("~.4f", [V]);
fmt_val(V) when is_binary(V) -> V;
fmt_val(V) -> io_lib:format("~p", [V]).

to_s(K) when is_atom(K) -> atom_to_list(K);
to_s(K) when is_list(K) -> K;
to_s(K) -> io_lib:format("~p", [K]).
