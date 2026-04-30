%% Json — translated from upstream/benchmarks/Ruby/json.rb.
%%
%% A hand-written JSON parser plus a polymorphic JsonValue hierarchy.
%% Doesn't depend on SOM Dictionary — uses its own HashIndexTable
%% (32-slot integer table indexed by name-length hash). The benchmark
%% parses a fixed ~25 KB string; verify_result/1 checks the resulting
%% JsonObject contains a "head" object and an "operations" array of
%% size 156.
%%
%% JsonValues are tagged tuples (records by another name): the type tag
%% lets us preserve polymorphic dispatch without an actual class
%% hierarchy.
-module(awfy_json).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, benchmark/0, verify_result/1]).

name() -> "Json".

inner_benchmark_loop(N) ->
    awfy_benchmark:default_loop(?MODULE, N).

verify_result(Result) ->
    case is_object(Result) of
        true ->
            Head = jobject_get(Result, <<"head">>),
            Ops = jobject_get(Result, <<"operations">>),
            is_object(Head) andalso is_array(Ops) andalso jarray_size(Ops) =:= 156;
        false ->
            false
    end.

%% Test data is a fixed ~25KB JSON document. Loaded lazily and cached
%% in the persistent_term store so we don't repeatedly read the file.
benchmark() ->
    Bin = test_input(),
    parse(Bin).

test_input() ->
    case persistent_term:get({?MODULE, test_input}, undefined) of
        undefined ->
            Path = filename:join(code:priv_dir(awfy), "rap_benchmark.json"),
            {ok, Bin} = file:read_file(Path),
            persistent_term:put({?MODULE, test_input}, Bin),
            Bin;
        Bin ->
            Bin
    end.

%%======================================================================
%% Polymorphic JsonValue (tagged tuples)
%%======================================================================
%% {jobject, NamesVec, ValuesVec, HashTable}
%% {jarray,  ValuesVec}
%% {jstring, Bin}
%% {jnumber, Bin}
%% {jliteral, null|true|false}

is_object({jobject, _, _, _}) -> true;
is_object(_) -> false.

is_array({jarray, _}) -> true;
is_array(_) -> false.

jarray_size({jarray, V}) -> awfy_som_vector:size(V).

jobject_get({jobject, Names, Values, Table}, Name) ->
    case jht_get(Table, Name) of
        -1 -> nil;
        Idx ->
            case awfy_som_vector:at(Names, Idx) =:= Name of
                true -> awfy_som_vector:at(Values, Idx);
                false -> erlang:error(not_implemented)
            end
    end.

jobject_new() ->
    {jobject, awfy_som_vector:new(), awfy_som_vector:new(), jht_new()}.

jobject_add({jobject, Names, Values, Table}, Name, Value) ->
    Names1 = awfy_som_vector:append(Names, Name),
    Values1 = awfy_som_vector:append(Values, Value),
    Table1 = jht_add(Table, Name, awfy_som_vector:size(Names)),
    {jobject, Names1, Values1, Table1}.

jarray_new() -> {jarray, awfy_som_vector:new()}.

jarray_add({jarray, V}, Value) -> {jarray, awfy_som_vector:append(V, Value)}.

%%======================================================================
%% HashIndexTable — 32-slot byte table.
%%======================================================================
-define(HT_SIZE, 32).

jht_new() ->
    %% 32 slots, all 0 (== empty).
    list_to_tuple(lists:duplicate(?HT_SIZE, 0)).

jht_add(Table, Name, Index) ->
    Slot = jht_slot(Name),
    Val =
        case Index < 16#ff of
            true -> (Index + 1) band 16#ff;
            false -> 0
        end,
    setelement(Slot + 1, Table, Val).

jht_get(Table, Name) ->
    Slot = jht_slot(Name),
    (element(Slot + 1, Table) band 16#ff) - 1.

jht_slot(Name) ->
    %% Same hash as the Ruby: name length * 1402589, mask with size-1.
    (byte_size(Name) * 1402589) band (?HT_SIZE - 1).

%%======================================================================
%% Parser state — a record threaded through every parse step.
%%======================================================================
-record(p, {
    input,
    %% byte position of CURRENT char. Starts at -1 so the first `read`
    %% advances to 0 (matching the Ruby Parser initial state).
    index = -1,
    %% the current character (byte int or eof)
    current = eof,
    capture_start = -1,
    capture_buffer = <<>>
}).

parse(Bin) ->
    P0 = #p{input = Bin},
    P1 = read(P0),
    P2 = skip_whitespace(P1),
    {Result, P3} = read_value(P2),
    P4 = skip_whitespace(P3),
    case is_eot(P4) of
        true -> Result;
        false -> erlang:error('unexpected character')
    end.

read_value(P) ->
    case P#p.current of
        $n -> read_null(P);
        $t -> read_true(P);
        $f -> read_false(P);
        $" -> read_string(P);
        $[ -> read_array(P);
        ${ -> read_object(P);
        C when C =:= $-; (C >= $0 andalso C =< $9) -> read_number(P);
        _ -> erlang:error({expected, value})
    end.

read_array(P0) ->
    P1 = read(P0),
    P2 = skip_whitespace(P1),
    case read_char(P2, $]) of
        {true, P3} ->
            {jarray_new(), P3};
        {false, P3} ->
            read_array_loop(jarray_new(), P3)
    end.

read_array_loop(Arr0, P0) ->
    P1 = skip_whitespace(P0),
    {Val, P2} = read_value(P1),
    Arr1 = jarray_add(Arr0, Val),
    P3 = skip_whitespace(P2),
    case read_char(P3, $,) of
        {true, P4} ->
            read_array_loop(Arr1, P4);
        {false, P4} ->
            case read_char(P4, $]) of
                {true, P5} -> {Arr1, P5};
                {false, _} -> erlang:error({expected, "',' or ']'"})
            end
    end.

read_object(P0) ->
    P1 = read(P0),
    P2 = skip_whitespace(P1),
    case read_char(P2, $}) of
        {true, P3} ->
            {jobject_new(), P3};
        {false, P3} ->
            read_object_loop(jobject_new(), P3)
    end.

read_object_loop(Obj0, P0) ->
    P1 = skip_whitespace(P0),
    {Name, P2} = read_name(P1),
    P3 = skip_whitespace(P2),
    P4 =
        case read_char(P3, $:) of
            {true, P4a} -> P4a;
            {false, _} -> erlang:error({expected, "':'"})
        end,
    P5 = skip_whitespace(P4),
    {Val, P6} = read_value(P5),
    Obj1 = jobject_add(Obj0, Name, Val),
    P7 = skip_whitespace(P6),
    case read_char(P7, $,) of
        {true, P8} ->
            read_object_loop(Obj1, P8);
        {false, P8} ->
            case read_char(P8, $}) of
                {true, P9} -> {Obj1, P9};
                {false, _} -> erlang:error({expected, "',' or '}'"})
            end
    end.

read_name(P) ->
    case P#p.current of
        $" -> read_string_internal(P);
        _ -> erlang:error({expected, name})
    end.

read_null(P0) ->
    P1 = read(P0),
    P2 = read_required_char(P1, $u),
    P3 = read_required_char(P2, $l),
    P4 = read_required_char(P3, $l),
    {{jliteral, null}, P4}.

read_true(P0) ->
    P1 = read(P0),
    P2 = read_required_char(P1, $r),
    P3 = read_required_char(P2, $u),
    P4 = read_required_char(P3, $e),
    {{jliteral, true}, P4}.

read_false(P0) ->
    P1 = read(P0),
    P2 = read_required_char(P1, $a),
    P3 = read_required_char(P2, $l),
    P4 = read_required_char(P3, $s),
    P5 = read_required_char(P4, $e),
    {{jliteral, false}, P5}.

read_required_char(P, Ch) ->
    case read_char(P, Ch) of
        {true, P1} -> P1;
        {false, _} -> erlang:error({expected, Ch})
    end.

read_string(P0) ->
    {Str, P1} = read_string_internal(P0),
    {{jstring, Str}, P1}.

read_string_internal(P0) ->
    P1 = read(P0),
    P2 = P1#p{capture_start = P1#p.index},
    P3 = read_string_chars(P2),
    {String, P4} = end_capture(P3),
    P5 = read(P4),
    {String, P5}.

read_string_chars(P) ->
    case P#p.current of
        $" -> P;
        $\\ ->
            P1 = pause_capture(P),
            P2 = read_escape(P1),
            P3 = P2#p{capture_start = P2#p.index},
            read_string_chars(P3);
        _ ->
            read_string_chars(read(P))
    end.

read_escape(P0) ->
    P1 = read(P0),
    Ch = P1#p.current,
    Buf =
        case Ch of
            $" -> <<(P1#p.capture_buffer)/binary, $">>;
            $/ -> <<(P1#p.capture_buffer)/binary, $/>>;
            $\\ -> <<(P1#p.capture_buffer)/binary, $\\>>;
            $b -> <<(P1#p.capture_buffer)/binary, $\b>>;
            $f -> <<(P1#p.capture_buffer)/binary, $\f>>;
            $n -> <<(P1#p.capture_buffer)/binary, $\n>>;
            $r -> <<(P1#p.capture_buffer)/binary, $\r>>;
            $t -> <<(P1#p.capture_buffer)/binary, $\t>>;
            _ -> erlang:error({expected, valid_escape_sequence})
        end,
    read(P1#p{capture_buffer = Buf}).

read_number(P0) ->
    P1 = P0#p{capture_start = P0#p.index},
    {_, P2} = read_char(P1, $-),
    First = P2#p.current,
    P3 =
        case read_digit(P2) of
            {true, P3a} -> P3a;
            {false, _} -> erlang:error({expected, digit})
        end,
    P4 =
        case First of
            $0 -> P3;
            _ -> read_digits(P3)
        end,
    P5 = read_fraction(P4),
    P6 = read_exponent(P5),
    {NumStr, P7} = end_capture(P6),
    {{jnumber, NumStr}, P7}.

read_digits(P) ->
    case read_digit(P) of
        {true, P1} -> read_digits(P1);
        {false, P1} -> P1
    end.

read_fraction(P) ->
    case read_char(P, $.) of
        {false, P1} ->
            P1;
        {true, P1} ->
            case read_digit(P1) of
                {true, P2} -> read_digits(P2);
                {false, _} -> erlang:error({expected, digit})
            end
    end.

read_exponent(P) ->
    Has =
        case read_char(P, $e) of
            {true, _} = R -> R;
            {false, _} -> read_char(P, $E)
        end,
    case Has of
        {false, P1} ->
            P1;
        {true, P1} ->
            P2 =
                case read_char(P1, $+) of
                    {true, Px} ->
                        Px;
                    {false, Px} ->
                        case read_char(Px, $-) of
                            {_, Py} -> Py
                        end
                end,
            case read_digit(P2) of
                {true, P3} -> read_digits(P3);
                {false, _} -> erlang:error({expected, digit})
            end
    end.

read_char(P, Ch) ->
    case P#p.current =:= Ch of
        true -> {true, read(P)};
        false -> {false, P}
    end.

read_digit(P) ->
    case is_digit(P) of
        true -> {true, read(P)};
        false -> {false, P}
    end.

skip_whitespace(P) ->
    case is_whitespace(P) of
        true -> skip_whitespace(read(P));
        false -> P
    end.

read(P = #p{input = Bin, index = I}) ->
    NewI = I + 1,
    Cur =
        case NewI < byte_size(Bin) of
            true -> binary:at(Bin, NewI);
            false -> eof
        end,
    P#p{index = NewI, current = Cur}.

pause_capture(P = #p{index = I, capture_start = Start, capture_buffer = Buf, input = Bin, current = Cur}) ->
    End =
        case Cur of
            eof -> I;
            _ -> I - 1
        end,
    Slice = binary:part(Bin, Start, End - Start + 1),
    P#p{capture_buffer = <<Buf/binary, Slice/binary>>, capture_start = -1}.

end_capture(P = #p{index = I, capture_start = Start, capture_buffer = Buf, input = Bin, current = Cur}) ->
    End =
        case Cur of
            eof -> I;
            _ -> I - 1
        end,
    Slice = binary:part(Bin, Start, End - Start + 1),
    Captured =
        case Buf of
            <<>> -> Slice;
            _ -> <<Buf/binary, Slice/binary>>
        end,
    {Captured, P#p{capture_start = -1, capture_buffer = <<>>}}.

is_whitespace(#p{current = $\s}) -> true;
is_whitespace(#p{current = $\t}) -> true;
is_whitespace(#p{current = $\n}) -> true;
is_whitespace(#p{current = $\r}) -> true;
is_whitespace(_) -> false.

is_digit(#p{current = C}) when C >= $0, C =< $9 -> true;
is_digit(_) -> false.

is_eot(#p{current = eof}) -> true;
is_eot(_) -> false.
