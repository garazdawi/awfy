# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Unicode do
  @moduledoc """
  Unicode-table-driven operations from `stdlib_bench_SUITE`'s
  unicode group. One family covering segmentation, normalization,
  and tokenization, with op-tagged inputs:

    * `graphemes_*`  — `:string.to_graphemes/1` across pure ASCII /
                       BMP / combining-mark inputs (4 KB each,
                       same byte count, very different per-call
                       cost).
    * `nfc_*`         — `:unicode.characters_to_nfc_binary/1`
                       spanning ASCII / precomposed / decomposed
                       (Latin + U+0301 → composes); the decomposed
                       path walks the full decomposition +
                       reordering tables.
    * `lexemes_*`     — `:string.lexemes/2` field-splitter:
                       sparse CSV, dense CSV, multi-separator
                       mixed; covers the hot path that powers
                       `:string.split` and friends.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "unicode"

  def inputs do
    %{
      "graphemes_ascii_4k" => {:graphemes, :binary.copy("a", 4096)},
      "graphemes_bmp_4k" => {:graphemes, :binary.copy("Я", div(4096, 2))},
      "graphemes_combining_4k" => {:graphemes, :binary.copy("á", div(4096, 3))},
      "nfc_pure_ascii_4k" => {:nfc, :binary.copy("a", 4096)},
      "nfc_precomposed_4k" => {:nfc, :binary.copy("Я", div(4096, 2))},
      "nfc_decomposed_4k" => {:nfc, :binary.copy("á", div(4096, 3))},
      "lexemes_csv_few" => {:lexemes, build_csv(32, 4, ","), [","]},
      "lexemes_csv_many" => {:lexemes, build_csv(256, 16, ","), [","]},
      "lexemes_mixed_seps" => {:lexemes, build_mixed(256, 16), [",", ";", "|"]}
    }
  end

  def run({:graphemes, bin}), do: :string.to_graphemes(bin)
  def run({:nfc, bin}), do: :unicode.characters_to_nfc_binary(bin)
  def run({:lexemes, bin, seps}), do: :string.lexemes(bin, seps)

  defp build_csv(token_count, token_len, sep) do
    token = :binary.copy("a", token_len)

    1..token_count
    |> Enum.map(fn _ -> token end)
    |> Enum.intersperse(sep)
    |> :erlang.iolist_to_binary()
  end

  defp build_mixed(token_count, token_len) do
    token = :binary.copy("a", token_len)
    seps = [",", ";", "|"]

    1..token_count
    |> Enum.map(fn _ -> token end)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {t, 0} -> [t]
      {t, i} -> [Enum.at(seps, rem(i, length(seps))), t]
    end)
    |> :erlang.iolist_to_binary()
  end
end
