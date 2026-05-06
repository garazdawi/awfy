# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.BinaryMatches do
  @moduledoc """
  `:binary.matches/2` — find every occurrence of a pattern in a
  haystack. The plural variant doesn't early-out, so the total
  cost is dominated by the number of hits + the haystack's
  length. Two regimes:

    * `no_match_64k` — zero hits, full scan; should be
      indistinguishable from the singular variant's no-match path.
    * `frequent_64k` — pattern at every 256 B (256 hits); the
      hot-path benchmark for log scanners and tokenisers.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "binary_matches"

  @haystack_size 64 * 1024
  @pattern <<"AWFY_NEEDLE">>

  def inputs do
    %{
      "no_match_64k" => {haystack(:no_match), @pattern},
      "frequent_64k" => {haystack(:frequent), @pattern}
    }
  end

  def run({haystack, pattern}), do: :binary.matches(haystack, pattern)

  defp haystack(:no_match), do: :binary.copy(<<"a">>, @haystack_size)

  defp haystack(:frequent) do
    chunk_size = 256 - byte_size(@pattern)
    chunk = <<:binary.copy(<<"a">>, chunk_size)::binary, @pattern::binary>>
    repeat = div(@haystack_size, byte_size(chunk))
    :binary.copy(chunk, repeat)
  end
end
