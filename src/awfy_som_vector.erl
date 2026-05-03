%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% SOM Vector — translated from upstream/benchmarks/Ruby/som.rb.
%%
%% A dynamic array with a sliding window (first_idx/last_idx) so that
%% remove_first is O(1). Backed by Erlang's `array` module: persistent
%% but with log-N access, the BEAM equivalent of Ruby's mutable Array.
%%
%% Convention: the Vec argument is always FIRST (state-first), so calls
%% can pipe through it cleanly in Elixir.
-module(awfy_som_vector).

-export([
    new/0,
    new/1,
    with/1,
    at/2,
    at_put/3,
    append/2,
    first/1,
    remove_first/1,
    remove/2,
    remove_all/1,
    each/2,
    has_some/2,
    get_one/2,
    size/1,
    capacity/1,
    is_empty/1,
    sort/2
]).

-define(INITIAL_SIZE, 10).

-record(vec, {storage = undefined, first_idx = 0, last_idx = 0}).

-opaque vector() :: #vec{}.
-export_type([vector/0]).

new() ->
    #vec{}.

new(Size) when Size > 0 ->
    #vec{storage = array:new(Size, [{default, nil}])};
new(0) ->
    #vec{}.

with(Elem) ->
    append(new(1), Elem).

at(#vec{storage = undefined}, _Idx) ->
    nil;
at(#vec{storage = Storage}, Idx) ->
    case Idx >= array:size(Storage) of
        true -> nil;
        false -> array:get(Idx, Storage)
    end.

at_put(V = #vec{storage = undefined}, Idx, Val) ->
    Size = max(Idx + 1, ?INITIAL_SIZE),
    Storage = array:new(Size, [{default, nil}]),
    at_put(V#vec{storage = Storage}, Idx, Val);
at_put(V = #vec{storage = Storage, last_idx = Last}, Idx, Val) ->
    StorageSz = array:size(Storage),
    Storage1 =
        case Idx >= StorageSz of
            true ->
                NewLen = grow_to(StorageSz * 2, Idx),
                resize_array(Storage, NewLen);
            false ->
                Storage
        end,
    Storage2 = array:set(Idx, Val, Storage1),
    NewLast = max(Last, Idx + 1),
    V#vec{storage = Storage2, last_idx = NewLast}.

grow_to(Cur, Idx) when Cur > Idx -> Cur;
grow_to(Cur, Idx) -> grow_to(Cur * 2, Idx).

resize_array(Old, NewLen) ->
    OldLen = array:size(Old),
    New = array:new(NewLen, [{default, nil}]),
    copy_array(0, OldLen, Old, New).

copy_array(I, OldLen, _Old, New) when I >= OldLen ->
    New;
copy_array(I, OldLen, Old, New) ->
    copy_array(I + 1, OldLen, Old, array:set(I, array:get(I, Old), New)).

append(V = #vec{storage = undefined}, Elem) ->
    Storage = array:new(?INITIAL_SIZE, [{default, nil}]),
    Storage1 = array:set(0, Elem, Storage),
    V#vec{storage = Storage1, last_idx = 1};
append(V = #vec{storage = Storage, last_idx = Last}, Elem) ->
    StorageSz = array:size(Storage),
    Storage1 =
        case Last >= StorageSz of
            true -> resize_array(Storage, 2 * StorageSz);
            false -> Storage
        end,
    Storage2 = array:set(Last, Elem, Storage1),
    V#vec{storage = Storage2, last_idx = Last + 1}.

first(#vec{storage = undefined}) ->
    nil;
first(#vec{first_idx = First, last_idx = Last}) when First >= Last ->
    nil;
first(#vec{first_idx = First, storage = Storage}) ->
    array:get(First, Storage).

remove_first(V = #vec{first_idx = First, last_idx = Last}) when First >= Last ->
    {nil, V};
remove_first(V = #vec{first_idx = First, storage = Storage}) ->
    {array:get(First, Storage), V#vec{first_idx = First + 1}}.

remove(V = #vec{storage = undefined}, _Obj) ->
    {false, V};
remove(V = #vec{first_idx = First, last_idx = Last}, _Obj) when First >= Last ->
    {false, V};
remove(V = #vec{storage = Storage}, Obj) ->
    Cap = array:size(Storage),
    NewArr = array:new(Cap, [{default, nil}]),
    {Found, NewLast, NewArr1} = remove_loop(V, Obj, NewArr, 0, false),
    case Found of
        true ->
            {true, V#vec{storage = NewArr1, first_idx = 0, last_idx = NewLast}};
        false ->
            {false, V}
    end.

remove_loop(#vec{first_idx = First, last_idx = Last, storage = Storage}, Obj, NewArr, NewLast, Found) ->
    remove_loop_iter(First, Last, Storage, Obj, NewArr, NewLast, Found).

remove_loop_iter(I, Last, _Storage, _Obj, NewArr, NewLast, Found) when I >= Last ->
    {Found, NewLast, NewArr};
remove_loop_iter(I, Last, Storage, Obj, NewArr, NewLast, Found) ->
    Item = array:get(I, Storage),
    case Item =:= Obj of
        true ->
            remove_loop_iter(I + 1, Last, Storage, Obj, NewArr, NewLast, true);
        false ->
            remove_loop_iter(
                I + 1,
                Last,
                Storage,
                Obj,
                array:set(NewLast, Item, NewArr),
                NewLast + 1,
                Found
            )
    end.

remove_all(V = #vec{storage = undefined}) ->
    V;
remove_all(V = #vec{storage = Storage}) ->
    V#vec{
        storage = array:new(array:size(Storage), [{default, nil}]),
        first_idx = 0,
        last_idx = 0
    }.

each(#vec{storage = undefined}, _Fun) ->
    ok;
each(#vec{first_idx = First, last_idx = Last, storage = Storage}, Fun) ->
    each_loop(First, Last, Storage, Fun).

each_loop(I, Last, _Storage, _Fun) when I >= Last ->
    ok;
each_loop(I, Last, Storage, Fun) ->
    Fun(array:get(I, Storage)),
    each_loop(I + 1, Last, Storage, Fun).

has_some(#vec{storage = undefined}, _Fun) ->
    false;
has_some(#vec{first_idx = First, last_idx = Last, storage = Storage}, Fun) ->
    has_some_loop(First, Last, Storage, Fun).

has_some_loop(I, Last, _Storage, _Fun) when I >= Last ->
    false;
has_some_loop(I, Last, Storage, Fun) ->
    case Fun(array:get(I, Storage)) of
        true -> true;
        false -> has_some_loop(I + 1, Last, Storage, Fun)
    end.

get_one(#vec{storage = undefined}, _Fun) ->
    nil;
get_one(#vec{first_idx = First, last_idx = Last, storage = Storage}, Fun) ->
    get_one_loop(First, Last, Storage, Fun).

get_one_loop(I, Last, _Storage, _Fun) when I >= Last ->
    nil;
get_one_loop(I, Last, Storage, Fun) ->
    Item = array:get(I, Storage),
    case Fun(Item) of
        true -> Item;
        false -> get_one_loop(I + 1, Last, Storage, Fun)
    end.

size(#vec{first_idx = First, last_idx = Last}) ->
    Last - First.

capacity(#vec{storage = undefined}) ->
    0;
capacity(#vec{storage = Storage}) ->
    array:size(Storage).

is_empty(#vec{first_idx = F, last_idx = L}) ->
    F =:= L.

%% Quicksort using DeltaBlue-pattern from som.rb. Cmp is fun(A, B) -> bool();
%% true means A should precede B.
sort(V = #vec{first_idx = F, last_idx = L}, _Cmp) when L - F =< 1 ->
    V;
sort(V = #vec{first_idx = F, last_idx = L, storage = Storage}, Cmp) ->
    Storage1 = sort_range(F, L - 1, Storage, Cmp),
    V#vec{storage = Storage1}.

sort_range(I, J, Storage, _Cmp) when J + 1 - I =< 1 ->
    Storage;
sort_range(I, J, Storage, Cmp) ->
    Di = array:get(I, Storage),
    Dj = array:get(J, Storage),
    {Storage1, Di1, Dj1} =
        case Cmp(Di, Dj) of
            true -> {Storage, Di, Dj};
            false -> {swap_arr(I, J, Storage), Dj, Di}
        end,
    N = J + 1 - I,
    case N > 2 of
        false ->
            Storage1;
        true ->
            Ij = (I + J) div 2,
            Dij0 = array:get(Ij, Storage1),
            {Storage2, Dij} =
                case Cmp(Di1, Dij0) of
                    true ->
                        case Cmp(Dij0, Dj1) of
                            true -> {Storage1, Dij0};
                            false -> {swap_arr(J, Ij, Storage1), Dj1}
                        end;
                    false ->
                        {swap_arr(I, Ij, Storage1), Di1}
                end,
            case N > 3 of
                false ->
                    Storage2;
                true ->
                    {Storage3, K, L1} = partition(I, J - 1, Storage2, Dij, Cmp),
                    Storage4 = sort_range(I, L1, Storage3, Cmp),
                    sort_range(K, J, Storage4, Cmp)
            end
    end.

partition(I, J, Storage, Dij, Cmp) ->
    partition_loop(I, J, Storage, Dij, Cmp).

partition_loop(K, L, Storage, Dij, Cmp) ->
    L1 = decr_while_succeeds(L, K, Storage, Dij, Cmp),
    K1 = K + 1,
    K2 = incr_while_succeeds(K1, L1, Storage, Dij, Cmp),
    case K2 =< L1 of
        true ->
            partition_loop(K2, L1, swap_arr(K2, L1, Storage), Dij, Cmp);
        false ->
            {Storage, K2, L1}
    end.

decr_while_succeeds(L, K, Storage, Dij, Cmp) when K =< L ->
    case Cmp(Dij, array:get(L, Storage)) of
        true -> decr_while_succeeds(L - 1, K, Storage, Dij, Cmp);
        false -> L
    end;
decr_while_succeeds(L, _K, _Storage, _Dij, _Cmp) ->
    L.

incr_while_succeeds(K, L, Storage, Dij, Cmp) when K =< L ->
    case Cmp(array:get(K, Storage), Dij) of
        true -> incr_while_succeeds(K + 1, L, Storage, Dij, Cmp);
        false -> K
    end;
incr_while_succeeds(K, _L, _Storage, _Dij, _Cmp) ->
    K.

swap_arr(I, J, Storage) ->
    Vi = array:get(I, Storage),
    Vj = array:get(J, Storage),
    array:set(J, Vi, array:set(I, Vj, Storage)).
