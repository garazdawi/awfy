%% SPDX-FileCopyrightText: Copyright (c) 2001-2016 Stefan Marr <git@stefan-marr.de>
%% SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
%% SPDX-License-Identifier: MIT

%% Mandelbrot — translated from upstream/benchmarks/Ruby/mandelbrot.rb.
%%
%% Bit-packed Mandelbrot escape-time computation. Verification depends
%% on inner_iterations (the size N): N=500 -> 191, N=750 -> 50, N=1 -> 128.
%% Pure float arithmetic in the inner loop with bit-shifting on a byte
%% accumulator.
-module(awfy_mandelbrot).

-behaviour(awfy_benchmark).

-export([name/0, inner_benchmark_loop/1, verify_result/2]).

name() -> "Mandelbrot".

inner_benchmark_loop(InnerIter) ->
    verify_result(mandelbrot(InnerIter), InnerIter).

verify_result(Result, 500) -> Result =:= 191;
verify_result(Result, 750) -> Result =:= 50;
verify_result(Result, 1) -> Result =:= 128;
verify_result(_Result, _) -> false.

mandelbrot(Size) ->
    y_loop(0, Size, 0).

y_loop(Y, Size, Sum) when Y >= Size ->
    Sum;
y_loop(Y, Size, Sum) ->
    Ci = (2.0 * Y / Size) - 1.0,
    Sum1 = x_loop(0, Size, Ci, 0, 0, Sum),
    y_loop(Y + 1, Size, Sum1).

x_loop(X, Size, _Ci, _ByteAcc, _BitNum, Sum) when X >= Size ->
    Sum;
x_loop(X, Size, Ci, ByteAcc, BitNum, Sum) ->
    Cr = (2.0 * X / Size) - 1.5,
    Escape = iterate(0, 0.0, 0.0, 0.0, Cr, Ci),
    ByteAcc1 = (ByteAcc bsl 1) + Escape,
    BitNum1 = BitNum + 1,
    {ByteAcc2, BitNum2, Sum1} =
        if
            BitNum1 =:= 8 ->
                {0, 0, Sum bxor ByteAcc1};
            X =:= Size - 1 ->
                Shifted = ByteAcc1 bsl (8 - BitNum1),
                {0, 0, Sum bxor Shifted};
            true ->
                {ByteAcc1, BitNum1, Sum}
        end,
    x_loop(X + 1, Size, Ci, ByteAcc2, BitNum2, Sum1).

%% Iterate up to 50 times. Returns 1 if escaped, 0 otherwise.
iterate(50, _Zrzr, _Zizi, _Zi, _Cr, _Ci) ->
    0;
iterate(_Z, Zrzr, Zizi, _Zi, _Cr, _Ci) when Zrzr + Zizi > 4.0 ->
    1;
iterate(Z, Zrzr, Zizi, Zi, Cr, Ci) ->
    Zr = Zrzr - Zizi + Cr,
    Zi1 = 2.0 * Zr * Zi + Ci,
    Zrzr1 = Zr * Zr,
    Zizi1 = Zi1 * Zi1,
    case Zrzr1 + Zizi1 > 4.0 of
        true -> 1;
        false -> iterate(Z + 1, Zrzr1, Zizi1, Zi1, Cr, Ci)
    end.
