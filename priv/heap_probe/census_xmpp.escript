#!/usr/bin/env escript
%%! -sname hpx
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: Apache-2.0
%% Attach to a running MongooseIM node, load a prebuilt heap_probe.beam via
%% code:load_binary (no on-node compiler needed), run one census, write result.
%% args: NodeStr CookieStr Kind("send"|"gc") DurationMs BeamPath OutFile
main([NodeStr, CookieStr, Kind, DurS, Beam, OutFile]) ->
    Node = list_to_atom(NodeStr),
    erlang:set_cookie(node(), list_to_atom(CookieStr)),
    case net_adm:ping(Node) of
        pong -> ok;
        pang -> io:format("PANG ~s (name/cookie mismatch)~n", [NodeStr]), halt(2)
    end,
    {ok, Bin} = file:read_file(Beam),
    {module, heap_probe} =
        rpc:call(Node, code, load_binary, [heap_probe, "heap_probe.beam", Bin]),
    Dur = list_to_integer(DurS),
    Res =
        case Kind of
            "send" ->
                rpc:call(Node, heap_probe, send_census,
                         [all, #{duration => Dur, multihop => true,
                                 fanout_cap => 200000}], Dur + 60000);
            "gc" ->
                rpc:call(Node, heap_probe, gc_census,
                         [all, #{duration => Dur}], Dur + 60000)
        end,
    Out = iolist_to_binary(rpc:call(Node, heap_probe, format, [Res])),
    ok = file:write_file(OutFile, Out),
    io:format("~s~n", [Out]).
