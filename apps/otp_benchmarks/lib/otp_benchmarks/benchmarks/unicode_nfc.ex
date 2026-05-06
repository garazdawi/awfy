# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.UnicodeNfc do
  @moduledoc """
  `:unicode.characters_to_nfc_binary/1` — Unicode normalization
  form C. Inputs span:

    * `pure_ascii_4k`   — already in NFC (every codepoint
                          composes trivially); fast path.
    * `precomposed_4k`  — already NFC, multi-byte chars
                          (Cyrillic precomposed); validates only.
    * `decomposed_4k`   — Latin base + combining acute that NFC
                          composes into single precomposed code-
                          points (e.g. `a` + U+0301 → U+00E1);
                          slowest path, walks the full
                          decomposition + reordering tables.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "unicode_nfc"

  def inputs do
    %{
      "pure_ascii_4k" => :binary.copy("a", 4096),
      "precomposed_4k" => :binary.copy("Я", div(4096, 2)),
      "decomposed_4k" => :binary.copy("á", div(4096, 3))
    }
  end

  def run(bin), do: :unicode.characters_to_nfc_binary(bin)
end
