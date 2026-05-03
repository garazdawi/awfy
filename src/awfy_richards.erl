%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% Richards — translated from upstream/benchmarks/Ruby/richards.rb.
%%
%% OS task scheduler simulation. The Ruby version is heavily
%% mutation-based: linked lists of TaskControlBlocks and Packets, each
%% with mutable .link fields, plus per-task private data records that
%% mutate during execution. Translating to BEAM: every "object" gets
%% an integer id; the scheduler state holds a `tasks` map and a
%% `packets` map; "mutation" puts an updated record back in the map.
%%
%% Polymorphic dispatch (different per-task closures from the four
%% create_* methods) is preserved as fun-valued fields on the
%% task-control-block record — exactly the BEAM analogue of Ruby's
%% `function.call(...)`.
-module(awfy_richards).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

-define(IDLER, 0).
-define(WORKER, 1).
-define(HANDLER_A, 2).
-define(HANDLER_B, 3).
-define(DEVICE_A, 4).
-define(DEVICE_B, 5).
-define(NUM_TYPES, 6).

-define(DEVICE_PACKET_KIND, 0).
-define(WORK_PACKET_KIND, 1).

-define(DATA_SIZE, 4).

-define(NO_TASK, nil).
-define(NO_WORK, nil).

-record(packet, {
    link = ?NO_WORK,
    kind,
    identity,
    datum = 0,
    data = {0, 0, 0, 0}
}).

-record(tcb, {
    link = ?NO_TASK,
    identity,
    function,
    priority,
    input = ?NO_WORK,
    handle,
    task_holding = false,
    task_waiting = false,
    packet_pending = false
}).

%% Per-task private data records.
-record(device_data, {pending = ?NO_WORK}).
-record(handler_data, {work_in = ?NO_WORK, device_in = ?NO_WORK}).
-record(idle_data, {control = 1, count = 10000}).
-record(worker_data, {destination = ?HANDLER_A, count = 0}).

-record(state, {
    %% Scheduler.
    task_list = ?NO_TASK,
    current_task = ?NO_TASK,
    current_task_identity = 0,
    %% identity -> identity (built once at start, never changes).
    task_table = {?NO_TASK, ?NO_TASK, ?NO_TASK, ?NO_TASK, ?NO_TASK, ?NO_TASK},
    queue_count = 0,
    hold_count = 0,
    %% identity -> tcb (mutable).
    tasks = #{},
    %% packet_ref -> packet (mutable; ref is a monotonic int).
    packets = #{},
    next_packet_ref = 0
}).

name() -> "Richards".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) -> Result.

benchmark() ->
    start_scheduler().

%%======================================================================
%% Scheduler entry
%%======================================================================
start_scheduler() ->
    S0 = #state{},
    S1 = create_idler(?IDLER, 0, ?NO_WORK, ts_running(), S0),
    {Wkq1, S2} = create_packet_state(?NO_WORK, ?WORKER, ?WORK_PACKET_KIND, S1),
    {Wkq2, S3} = create_packet_state(Wkq1, ?WORKER, ?WORK_PACKET_KIND, S2),
    S4 = create_worker(?WORKER, 1000, Wkq2, ts_waiting_with_packet(), S3),

    {WkqA1, S5} = create_packet_state(?NO_WORK, ?DEVICE_A, ?DEVICE_PACKET_KIND, S4),
    {WkqA2, S6} = create_packet_state(WkqA1, ?DEVICE_A, ?DEVICE_PACKET_KIND, S5),
    {WkqA3, S7} = create_packet_state(WkqA2, ?DEVICE_A, ?DEVICE_PACKET_KIND, S6),
    S8 = create_handler(?HANDLER_A, 2000, WkqA3, ts_waiting_with_packet(), S7),

    {WkqB1, S9} = create_packet_state(?NO_WORK, ?DEVICE_B, ?DEVICE_PACKET_KIND, S8),
    {WkqB2, S10} = create_packet_state(WkqB1, ?DEVICE_B, ?DEVICE_PACKET_KIND, S9),
    {WkqB3, S11} = create_packet_state(WkqB2, ?DEVICE_B, ?DEVICE_PACKET_KIND, S10),
    S12 = create_handler(?HANDLER_B, 3000, WkqB3, ts_waiting_with_packet(), S11),

    S13 = create_device(?DEVICE_A, 4000, ?NO_WORK, ts_waiting(), S12),
    S14 = create_device(?DEVICE_B, 5000, ?NO_WORK, ts_waiting(), S13),

    S15 = schedule(S14),
    S15#state.queue_count =:= 23246 andalso S15#state.hold_count =:= 9297.

%%======================================================================
%% TaskState helpers (fresh records with given flag combos)
%%======================================================================
ts_running() -> {false, false, false}.
ts_waiting() -> {false, true, false}.
ts_waiting_with_packet() -> {true, true, false}.

%%======================================================================
%% Task creation
%%======================================================================
create_idler(Identity, Priority, Work, State, S) ->
    Data = #idle_data{},
    Fun = fun(WorkP, IdleData, Sch) -> idler_step(WorkP, IdleData, Sch) end,
    create_task(Identity, Priority, Work, State, Data, Fun, S).

create_worker(Identity, Priority, Work, State, S) ->
    Data = #worker_data{},
    Fun = fun(WorkP, WD, Sch) -> worker_step(WorkP, WD, Sch) end,
    create_task(Identity, Priority, Work, State, Data, Fun, S).

create_handler(Identity, Priority, Work, State, S) ->
    Data = #handler_data{},
    Fun = fun(WorkP, HD, Sch) -> handler_step(WorkP, HD, Sch) end,
    create_task(Identity, Priority, Work, State, Data, Fun, S).

create_device(Identity, Priority, Work, State, S) ->
    Data = #device_data{},
    Fun = fun(WorkP, DD, Sch) -> device_step(WorkP, DD, Sch) end,
    create_task(Identity, Priority, Work, State, Data, Fun, S).

create_task(Identity, Priority, Work, {PP, TW, TH}, Data, Fun, S) ->
    TCB = #tcb{
        link = S#state.task_list,
        identity = Identity,
        function = Fun,
        priority = Priority,
        input = Work,
        handle = Data,
        packet_pending = PP,
        task_waiting = TW,
        task_holding = TH
    },
    Tasks1 = maps:put(Identity, TCB, S#state.tasks),
    Table1 = setelement(Identity + 1, S#state.task_table, Identity),
    S#state{task_list = Identity, tasks = Tasks1, task_table = Table1}.

%%======================================================================
%% Packet creation (state-threaded — packets live in a map by ref)
%%======================================================================
create_packet_state(LinkRef, Identity, Kind, S) ->
    Ref = S#state.next_packet_ref,
    Pkt = #packet{link = LinkRef, identity = Identity, kind = Kind},
    {Ref, S#state{
        packets = maps:put(Ref, Pkt, S#state.packets),
        next_packet_ref = Ref + 1
    }}.

%%======================================================================
%% Schedule loop
%%======================================================================
schedule(S = #state{task_list = Head}) ->
    schedule_loop(Head, S).

schedule_loop(?NO_TASK, S) ->
    S;
schedule_loop(Cur, S) ->
    TCB = maps:get(Cur, S#state.tasks),
    case is_task_holding_or_waiting(TCB) of
        true ->
            schedule_loop(TCB#tcb.link, S);
        false ->
            S1 = S#state{current_task = Cur, current_task_identity = TCB#tcb.identity},
            {NextCur, S2} = run_task(TCB, S1),
            schedule_loop(NextCur, S2)
    end.

is_task_holding_or_waiting(#tcb{task_holding = TH, task_waiting = TW, packet_pending = PP}) ->
    TH orelse (not PP andalso TW).

is_waiting_with_packet(#tcb{task_holding = TH, task_waiting = TW, packet_pending = PP}) ->
    PP andalso TW andalso not TH.

run_task(TCB, S) ->
    {Message, TCB1, S1} =
        case is_waiting_with_packet(TCB) of
            true ->
                Msg = TCB#tcb.input,
                MsgPkt = maps:get(Msg, S#state.packets),
                NewInput = MsgPkt#packet.link,
                NewTcb =
                    case NewInput of
                        ?NO_WORK -> state_running(TCB#tcb{input = NewInput});
                        _ -> state_packet_pending(TCB#tcb{input = NewInput})
                    end,
                {Msg, NewTcb, S};
            false ->
                {?NO_WORK, TCB, S}
        end,
    %% Persist updated TCB before invoking the function (function may mutate it again).
    S2 = put_tcb(TCB1, S1),
    Fun = TCB1#tcb.function,
    Handle = TCB1#tcb.handle,
    Fun(Message, Handle, S2).

%%======================================================================
%% TCB state mutations.
%%
%% Critical distinction (took an hour of debugging to spot): the
%% Ruby has both GRANULAR setters (attr_writer for each flag) and
%% STATE-SETTER methods (running/packet_pending/waiting that flip
%% multiple flags at once).
%%
%% Scheduler#wait/hold_self/release and add_input_and_check_priority
%% use the granular setters — they only touch ONE flag. Inside
%% run_task, the state-setter methods running/packet_pending are
%% called when input is exhausted or partially drained.
%%======================================================================

%% State-setter methods (multi-flag) — only called from run_task.
state_running(TCB) ->
    TCB#tcb{packet_pending = false, task_waiting = false, task_holding = false}.
state_packet_pending(TCB) ->
    TCB#tcb{packet_pending = true, task_waiting = false, task_holding = false}.

put_tcb(TCB, S) ->
    S#state{tasks = maps:put(TCB#tcb.identity, TCB, S#state.tasks)}.

%%======================================================================
%% Scheduler primitives (return {NextTaskId, NewState})
%%======================================================================
wait(S) ->
    Cur = S#state.current_task,
    TCB = maps:get(Cur, S#state.tasks),
    %% Granular: only flip task_waiting=true.
    TCB1 = TCB#tcb{task_waiting = true},
    {Cur, put_tcb(TCB1, S)}.

hold_self(S) ->
    Cur = S#state.current_task,
    TCB = maps:get(Cur, S#state.tasks),
    %% Granular: only flip task_holding=true.
    TCB1 = TCB#tcb{task_holding = true},
    S1 = put_tcb(TCB1, S),
    S2 = S1#state{hold_count = S1#state.hold_count + 1},
    {TCB1#tcb.link, S2}.

release(Identity, S) ->
    case find_task(Identity, S) of
        ?NO_TASK ->
            {?NO_TASK, S};
        TCB ->
            TCB1 = TCB#tcb{task_holding = false},
            S1 = put_tcb(TCB1, S),
            CurTcb = maps:get(S#state.current_task, S1#state.tasks),
            Next =
                case TCB1#tcb.priority > CurTcb#tcb.priority of
                    true -> TCB1#tcb.identity;
                    false -> S#state.current_task
                end,
            {Next, S1}
    end.

queue_packet(PktRef, S) ->
    Pkt = maps:get(PktRef, S#state.packets),
    case find_task(Pkt#packet.identity, S) of
        ?NO_TASK ->
            {?NO_TASK, S};
        TCB ->
            S1 = S#state{queue_count = S#state.queue_count + 1},
            Pkt1 = Pkt#packet{link = ?NO_WORK, identity = S#state.current_task_identity},
            S2 = S1#state{packets = maps:put(PktRef, Pkt1, S1#state.packets)},
            CurTcb = maps:get(S2#state.current_task, S2#state.tasks),
            add_input_and_check_priority(TCB, PktRef, CurTcb, S2)
    end.

add_input_and_check_priority(TCB, PktRef, OldTask, S) ->
    case TCB#tcb.input of
        ?NO_WORK ->
            TCB1 = (TCB#tcb{input = PktRef})#tcb{packet_pending = true},
            S1 = put_tcb(TCB1, S),
            Next =
                case TCB1#tcb.priority > OldTask#tcb.priority of
                    true -> TCB1#tcb.identity;
                    false -> OldTask#tcb.identity
                end,
            {Next, S1};
        Head ->
            S1 = S#state{packets = append_packet(PktRef, Head, S#state.packets)},
            {OldTask#tcb.identity, S1}
    end.

append_packet(PktRef, QueueHead, Packets0) ->
    %% packet.link := nil
    Pkt = maps:get(PktRef, Packets0),
    Packets1 = maps:put(PktRef, Pkt#packet{link = ?NO_WORK}, Packets0),
    case QueueHead of
        ?NO_WORK ->
            %% Caller should have used PktRef directly; defensive.
            Packets1;
        _ ->
            walk_and_append(QueueHead, PktRef, Packets1)
    end.

walk_and_append(MouseRef, NewRef, Packets) ->
    Mouse = maps:get(MouseRef, Packets),
    case Mouse#packet.link of
        ?NO_WORK ->
            maps:put(MouseRef, Mouse#packet{link = NewRef}, Packets);
        NextRef ->
            walk_and_append(NextRef, NewRef, Packets)
    end.

find_task(Identity, S) ->
    case element(Identity + 1, S#state.task_table) of
        ?NO_TASK -> ?NO_TASK;
        Id -> maps:get(Id, S#state.tasks)
    end.

%%======================================================================
%% Per-task step functions (the four polymorphic behaviors)
%%======================================================================
idler_step(_Work, IdleData, S) ->
    Count = IdleData#idle_data.count - 1,
    case Count of
        0 ->
            put_handle(S, IdleData#idle_data{count = Count}),
            hold_self(S);
        _ ->
            case IdleData#idle_data.control band 1 of
                0 ->
                    NewControl = IdleData#idle_data.control div 2,
                    NewData = IdleData#idle_data{count = Count, control = NewControl},
                    S1 = put_handle(S, NewData),
                    release(?DEVICE_A, S1);
                _ ->
                    NewControl = (IdleData#idle_data.control div 2) bxor 53256,
                    NewData = IdleData#idle_data{count = Count, control = NewControl},
                    S1 = put_handle(S, NewData),
                    release(?DEVICE_B, S1)
            end
    end.

worker_step(?NO_WORK, _WD, S) ->
    wait(S);
worker_step(WorkPktRef, WD0, S0) ->
    Dest = case WD0#worker_data.destination of
        ?HANDLER_A -> ?HANDLER_B;
        _ -> ?HANDLER_A
    end,
    WD1 = WD0#worker_data{destination = Dest},
    %% Fill in 4 data slots in work packet.
    {Pkt0, S1} = update_work_packet(WorkPktRef, Dest, WD1, S0),
    {WD2, Pkt1} = fill_work_data(0, WD1, Pkt0),
    S2 = S1#state{packets = maps:put(WorkPktRef, Pkt1, S1#state.packets)},
    S3 = put_handle(S2, WD2),
    queue_packet(WorkPktRef, S3).

update_work_packet(WorkPktRef, Dest, _WD, S) ->
    Pkt = maps:get(WorkPktRef, S#state.packets),
    {Pkt#packet{identity = Dest, datum = 0}, S}.

fill_work_data(?DATA_SIZE, WD, Pkt) ->
    {WD, Pkt};
fill_work_data(I, WD0, Pkt0) ->
    Count1 = WD0#worker_data.count + 1,
    Count2 =
        case Count1 > 26 of
            true -> 1;
            false -> Count1
        end,
    Datum = 65 + Count2 - 1,
    Data1 = setelement(I + 1, Pkt0#packet.data, Datum),
    Pkt1 = Pkt0#packet{data = Data1},
    fill_work_data(I + 1, WD0#worker_data{count = Count2}, Pkt1).

handler_step(WorkPktRef, HD0, S0) ->
    %% Step 1: append the incoming packet to the right queue (if any).
    {HD1, S1} =
        case WorkPktRef of
            ?NO_WORK ->
                {HD0, S0};
            _ ->
                Pkt = maps:get(WorkPktRef, S0#state.packets),
                case Pkt#packet.kind of
                    ?WORK_PACKET_KIND ->
                        {NewHead, Packets1} = append_to_queue(
                            WorkPktRef, HD0#handler_data.work_in, S0#state.packets
                        ),
                        {HD0#handler_data{work_in = NewHead},
                            S0#state{packets = Packets1}};
                    _ ->
                        {NewHead, Packets1} = append_to_queue(
                            WorkPktRef, HD0#handler_data.device_in, S0#state.packets
                        ),
                        {HD0#handler_data{device_in = NewHead},
                            S0#state{packets = Packets1}}
                end
        end,
    %% Step 2: process the work_in queue.
    case HD1#handler_data.work_in of
        ?NO_WORK ->
            S2 = put_handle(S1, HD1),
            wait(S2);
        WorkRef ->
            WorkPkt = maps:get(WorkRef, S1#state.packets),
            Count = WorkPkt#packet.datum,
            case Count >= ?DATA_SIZE of
                true ->
                    HD2 = HD1#handler_data{work_in = WorkPkt#packet.link},
                    S2 = put_handle(S1, HD2),
                    queue_packet(WorkRef, S2);
                false ->
                    case HD1#handler_data.device_in of
                        ?NO_WORK ->
                            S2 = put_handle(S1, HD1),
                            wait(S2);
                        DevRef ->
                            DevPkt = maps:get(DevRef, S1#state.packets),
                            HD2 = HD1#handler_data{device_in = DevPkt#packet.link},
                            DevPkt1 = DevPkt#packet{
                                datum = element(Count + 1, WorkPkt#packet.data)
                            },
                            WorkPkt1 = WorkPkt#packet{datum = Count + 1},
                            S2 = S1#state{
                                packets = maps:put(
                                    DevRef,
                                    DevPkt1,
                                    maps:put(WorkRef, WorkPkt1, S1#state.packets)
                                )
                            },
                            S3 = put_handle(S2, HD2),
                            queue_packet(DevRef, S3)
                    end
            end
    end.

%% Append PktRef onto the chain whose head is QueueHead. Returns the
%% new head ref (unchanged if QueueHead was non-nil) and updated packets.
%% Mirrors RBObject#append in the Ruby source.
append_to_queue(PktRef, QueueHead, Packets0) ->
    Pkt = maps:get(PktRef, Packets0),
    Packets1 = maps:put(PktRef, Pkt#packet{link = ?NO_WORK}, Packets0),
    case QueueHead of
        ?NO_WORK ->
            {PktRef, Packets1};
        _ ->
            {QueueHead, walk_and_append(QueueHead, PktRef, Packets1)}
    end.

device_step(?NO_WORK, DD, S) ->
    case DD#device_data.pending of
        ?NO_WORK ->
            wait(S);
        Pending ->
            DD1 = DD#device_data{pending = ?NO_WORK},
            S1 = put_handle(S, DD1),
            queue_packet(Pending, S1)
    end;
device_step(WorkPktRef, DD, S) ->
    DD1 = DD#device_data{pending = WorkPktRef},
    S1 = put_handle(S, DD1),
    hold_self(S1).

%%======================================================================
%% Handle update
%%======================================================================
put_handle(S, NewHandle) ->
    Cur = S#state.current_task,
    TCB = maps:get(Cur, S#state.tasks),
    TCB1 = TCB#tcb{handle = NewHandle},
    S#state{tasks = maps:put(Cur, TCB1, S#state.tasks)}.
