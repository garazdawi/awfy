# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.BinaryMatch do
  @moduledoc """
  `:binary.match/2` (singular) and `:binary.matches/2` (plural)
  against a 64 KB haystack across the BM-skip-table BIF's three
  production-relevant regimes:

    * `first_no_match`  — pattern absent; full O(n) scan with the
                          skip table active
    * `first_eventual`  — single hit at ~90% of the haystack
    * `first_frequent`  — pattern every 256 B; first-hit early-out
                          cost
    * `all_no_match`    — plural variant, zero hits → indistin-
                          guishable from `first_no_match` since
                          the early-out path doesn't trigger
    * `all_frequent`    — plural variant, 256 hits in 64 KB; hot
                          path for log scanners and tokenisers

  Pattern is a static 11-byte string so BM-skip preprocessing
  cost stays equal across inputs.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "binary_match"

  @haystack_size 64 * 1024
  @pattern <<"AWFY_NEEDLE">>

  def inputs do
    %{
      "first_no_match_64k" => {:first, :no_match},
      "first_eventual_64k" => {:first, :eventual},
      "first_frequent_64k" => {:first, :frequent},
      "all_no_match_64k" => {:all, :no_match},
      "all_frequent_64k" => {:all, :frequent}
    }
  end

  def setup({op, distribution}), do: {op, haystack(distribution), @pattern}

  def run({:first, haystack, pattern}), do: :binary.match(haystack, pattern)
  def run({:all, haystack, pattern}), do: :binary.matches(haystack, pattern)

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
