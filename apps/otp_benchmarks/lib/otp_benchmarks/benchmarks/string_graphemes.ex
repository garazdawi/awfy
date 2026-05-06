# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.StringGraphemes do
  @moduledoc """
  `:string.to_graphemes/1` across input shapes that exercise the
  Unicode segmentation table:

    * `ascii_4k`         — pure ASCII; one byte per grapheme,
                           hits the fast path that skips combining-
                           character lookups entirely.
    * `bmp_4k`            — Basic Multilingual Plane characters
                           (Cyrillic, Greek); 2 bytes per char in
                           UTF-8, one grapheme per char, no
                           combining marks.
    * `combining_4k`      — Latin base + combining acute accent
                           (U+0301); each grapheme cluster is a
                           sequence of 2 codepoints, so the table
                           lookup runs twice per grapheme.

  All inputs are 4 KB UTF-8 binaries — same byte count, very
  different per-call cost.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "string_graphemes"

  def inputs do
    %{
      "ascii_4k" => :binary.copy("a", 4096),
      "bmp_4k" => :binary.copy("Я", div(4096, 2)),
      "combining_4k" => :binary.copy("á", div(4096, 3))
    }
  end

  def run(bin), do: :string.to_graphemes(bin)
end
