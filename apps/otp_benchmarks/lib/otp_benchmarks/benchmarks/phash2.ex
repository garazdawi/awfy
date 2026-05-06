# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Phash2 do
  @moduledoc """
  `:erlang.phash2/1` across the input shapes that exercise its
  internal dispatch paths.

  Modelled on `phash2_benchmark_tests` from upstream OTP's
  `lib/stdlib/test/hash_SUITE.erl`. We keep one scenario per input
  shape (int / binary / list / tuple / map / atom) at sizes that
  cross the BEAM's interesting boundaries:

    * small/large integers — fixnum vs bignum dispatch
    * 8 / 64 / 4096-byte binaries — refcount binary boundary at 64 B
    * 10 / 1000-element list — short loop vs sustained
    * 10 / 1000-element tuple — same, tuple-shaped
    * 5 / 32 / 100-key map — flatmap vs HAMT (cutover at 32)
    * single atom — atom-tag fast path

  Inputs are static and shared across iterations: phash2 has no
  input-dependent caching, so re-hashing the same term measures the
  per-call cost we care about.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "phash2"

  def inputs do
    %{
      "atom" => :a_typical_atom,
      "int_fixnum" => 42,
      "int_bignum" => 12_345_678_901_234_567_890,
      "binary_8" => :binary.copy(<<"abcdefgh">>, 1),
      "binary_64" => :binary.copy(<<"abcdefgh">>, 8),
      "binary_4k" => :binary.copy(<<"abcdefgh">>, 512),
      "list_10" => Enum.to_list(1..10),
      "list_1000" => Enum.to_list(1..1000),
      "tuple_10" => List.to_tuple(Enum.to_list(1..10)),
      "tuple_1000" => List.to_tuple(Enum.to_list(1..1000)),
      "map_5" => Map.new(1..5, &{&1, &1}),
      "map_32" => Map.new(1..32, &{&1, &1}),
      "map_100" => Map.new(1..100, &{&1, &1})
    }
  end

  def run(input), do: :erlang.phash2(input)
end
