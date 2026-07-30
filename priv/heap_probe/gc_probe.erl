%% SPDX-License-Identifier: Apache-2.0
-module(gc_probe).
-moduledoc("""
Characterize what a live node's GC is actually spending time on (#75 follow-on:
"a lot of time in GC — what is it doing, can we do less?"). Run ON the target
node (rpc/attach) while it's under load:

  gc_probe:census(10000)   %% 10s window

Reports, over the window:
  * msacc time breakdown — GC as a fraction of scheduler time (the headline),
    plus the other states (emulator/alloc/send/...), so you see how big GC is;
  * total GCs + words reclaimed (statistics/garbage_collection);
  * the processes with the most *expensive* GCs (system_monitor long_gc/
    large_heap), each enriched with the knobs that decide the lever:
    message_queue_len, message_queue_data (on_heap|off_heap), fullsweep_after,
    min_heap_size, heap sizes, current_function.

Needs microstate accounting (enabled here via system_flag). Best-effort; the
long_gc threshold is deliberately low (2ms) to catch the meaningful GCs.
""").
-export([census/1, census/2, format/1]).

census(Duration) -> census(Duration, #{}).

census(Duration, Opts) ->
    LongGc = maps:get(long_gc_ms, Opts, 2),
    LargeHeap = maps:get(large_heap_words, Opts, 500000),
    _ = erlang:system_flag(microstate_accounting, true),
    _ = erlang:system_flag(microstate_accounting, reset),
    Old = erlang:system_monitor(self(), [{long_gc, LongGc}, {large_heap, LargeHeap}]),
    {GC0, W0, _} = erlang:statistics(garbage_collection),
    Deadline = erlang:monotonic_time(millisecond) + Duration,
    Acc = collect(Deadline, #{}),
    Msacc = erlang:statistics(microstate_accounting),
    {GC1, W1, _} = erlang:statistics(garbage_collection),
    _ = erlang:system_monitor(Old),
    WS = erlang:system_info(wordsize),
    #{census => gc_time,
      duration_ms => Duration,
      schedulers => erlang:system_info(schedulers_online),
      msacc => msacc_summary(Msacc),
      total_gcs => GC1 - GC0,
      reclaimed_bytes => (W1 - W0) * WS,
      long_gc_threshold_ms => LongGc,
      expensive_gc_procs => top_procs(Acc, 12)}.

collect(Deadline, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = Deadline - Now,
    case Wait =< 0 of
        true -> Acc;
        false ->
            receive
                {monitor, Pid, long_gc, Info} -> collect(Deadline, bump(Acc, Pid, long_gc, Info));
                {monitor, Pid, large_heap, Info} -> collect(Deadline, bump(Acc, Pid, large_heap, Info));
                _ -> collect(Deadline, Acc)
            after Wait -> Acc
            end
    end.

bump(Acc, Pid, Kind, Info) ->
    T = proplists:get_value(timeout, Info, 0),          % gc duration (ms) for long_gc
    H = proplists:get_value(heap_size, Info, 0)
        + proplists:get_value(old_heap_size, Info, 0)
        + proplists:get_value(mbuf_size, Info, 0),
    E = maps:get(Pid, Acc, #{long_gc => 0, large_heap => 0, gc_ms => 0, max_ms => 0, max_heap => 0}),
    E1 = E#{Kind := maps:get(Kind, E) + 1,
            gc_ms := maps:get(gc_ms, E) + T,
            max_ms := max(maps:get(max_ms, E), T),
            max_heap := max(maps:get(max_heap, E), H)},
    Acc#{Pid => E1}.

top_procs(Acc, N) ->
    WS = erlang:system_info(wordsize),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> maps:get(gc_ms, A) >= maps:get(gc_ms, B) end,
                        maps:to_list(Acc)),
    [begin
         GcInfo = pinfo(Pid, garbage_collection, []),
         #{pid => Pid,
           name => pinfo(Pid, registered_name, '-'),
           current => pinfo(Pid, current_function, '-'),
           long_gcs => maps:get(long_gc, E),
           large_heaps => maps:get(large_heap, E),
           gc_ms_total => maps:get(gc_ms, E),
           gc_ms_max => maps:get(max_ms, E),
           max_heap_bytes => maps:get(max_heap, E) * WS,
           msg_queue_len => pinfo(Pid, message_queue_len, 0),
           msg_queue_data => pinfo(Pid, message_queue_data, '-'),
           fullsweep_after => proplists:get_value(fullsweep_after, GcInfo, '-'),
           min_heap_size => proplists:get_value(min_heap_size, GcInfo, '-'),
           minor_gcs => proplists:get_value(minor_gcs, GcInfo, '-')}
     end || {Pid, E} <- lists:sublist(Sorted, N)].

pinfo(Pid, Key, Default) ->
    case process_info(Pid, Key) of
        {Key, V} -> V;
        _ -> Default
    end.

%% Sum msacc counters across all schedulers; express each state as a % of the
%% total, and GC as a % of *active* time (excluding sleep).
msacc_summary(Data) when is_list(Data) ->
    Sched = [C || #{type := scheduler, counters := C} <- Data],
    Sum = lists:foldl(fun(C, A) ->
                          maps:fold(fun(K, V, Ai) -> maps:update_with(K, fun(X) -> X + V end, V, Ai) end, A, C)
                      end, #{}, Sched),
    Total = lists:sum(maps:values(Sum)),
    Sleep = maps:get(sleep, Sum, 0),
    Active = max(1, Total - Sleep),
    Gc = maps:get(gc, Sum, 0) + maps:get(gc_full, Sum, 0),
    #{gc_pct_of_active => pct(Gc, Active),
      gc_pct_of_total => pct(Gc, max(1, Total)),
      states_pct_of_active =>
          maps:from_list([{K, pct(V, Active)} || {K, V} <- maps:to_list(Sum), K =/= sleep])};
msacc_summary(_) -> #{error => no_microstate_accounting}.

pct(_, 0) -> 0.0;
pct(A, B) -> round(A * 1000 / B) / 10.

format(#{msacc := M} = R) ->
    io:format("== gc_probe (~pms, ~p schedulers) ==~n", [maps:get(duration_ms, R), maps:get(schedulers, R)]),
    io:format("GC time: ~p% of active scheduler time (~p% of total incl sleep)~n",
              [maps:get(gc_pct_of_active, M, '?'), maps:get(gc_pct_of_total, M, '?')]),
    io:format("scheduler state %% (of active): ~p~n", [maps:get(states_pct_of_active, M, #{})]),
    io:format("total GCs: ~p   reclaimed: ~.1f MB~n",
              [maps:get(total_gcs, R), maps:get(reclaimed_bytes, R) / 1048576]),
    io:format("~n-- most expensive-GC processes --~n"),
    [io:format("  ~p ~p  gc=~pms(max ~pms) longgc=~p bigheap=~p  mqlen=~p mqd=~p "
               "fullsweep=~p minheap=~p minors=~p heap<=~.1fMB  ~p~n",
               [maps:get(pid, P), maps:get(name, P), maps:get(gc_ms_total, P), maps:get(gc_ms_max, P),
                maps:get(long_gcs, P), maps:get(large_heaps, P), maps:get(msg_queue_len, P),
                maps:get(msg_queue_data, P), maps:get(fullsweep_after, P), maps:get(min_heap_size, P),
                maps:get(minor_gcs, P), maps:get(max_heap_bytes, P) / 1048576, maps:get(current, P)])
     || P <- maps:get(expensive_gc_procs, R, [])],
    ok.
