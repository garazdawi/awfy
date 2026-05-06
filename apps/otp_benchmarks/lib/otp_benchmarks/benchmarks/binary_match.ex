# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.BinaryMatch do
  @moduledoc """
  `:binary.match/2` against a 64 KB haystack in three regimes:

    * `no_match`  — pattern doesn't appear; the BIF scans the
      whole haystack with the Boyer-Moore skip table, paying full
      O(n) cost.
    * `eventual`  — pattern appears once near the end of the
      haystack (~90% in); measures the steady-state scan with
      one final positional return.
    * `frequent`  — pattern appears every 256 bytes; the BIF
      returns on the first hit so this measures the early-out
      path's startup cost.

  Inputs are static binaries built once per scenario.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "binary_match"

  @haystack_size 64 * 1024
  @pattern <<"AWFY_NEEDLE">>

  def inputs do
    %{
      "no_match_64k" => {haystack(:no_match), @pattern},
      "eventual_64k" => {haystack(:eventual), @pattern},
      "frequent_64k" => {haystack(:frequent), @pattern}
    }
  end

  def run({haystack, pattern}), do: :binary.match(haystack, pattern)

  defp haystack(:no_match), do: :binary.copy(<<"a">>, @haystack_size)

  defp haystack(:eventual) do
    fill = :binary.copy(<<"a">>, trunc(@haystack_size * 0.9))
    rest = :binary.copy(<<"a">>, @haystack_size - byte_size(fill) - byte_size(@pattern))
    <<fill::binary, @pattern::binary, rest::binary>>
  end

  defp haystack(:frequent) do
    chunk_size = 256 - byte_size(@pattern)
    chunk = <<:binary.copy(<<"a">>, chunk_size)::binary, @pattern::binary>>
    repeat = div(@haystack_size, byte_size(chunk))
    :binary.copy(chunk, repeat)
  end
end
