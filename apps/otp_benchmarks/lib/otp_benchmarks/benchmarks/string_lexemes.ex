# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.StringLexemes do
  @moduledoc """
  `:string.lexemes/2` — tokenize a string by a separator set.
  Mirrors classic field-splitting hot paths (CSV, PATH-style
  env vars). Inputs vary the token density:

    * `csv_few` — 32 4-byte tokens separated by `,`; few
                  expensive separator transitions.
    * `csv_many` — 256 16-byte tokens; sustained separator
                   handling.
    * `mixed_seps` — same content but multiple separator chars
                     (`,;|`); exercises the multi-separator path
                     that does extra per-byte work in the
                     separator-membership check.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "string_lexemes"

  def inputs do
    %{
      "csv_few" => {build_csv(32, 4, ","), [","]},
      "csv_many" => {build_csv(256, 16, ","), [","]},
      "mixed_seps" => {build_mixed(256, 16), [",", ";", "|"]}
    }
  end

  def run({input, seps}), do: :string.lexemes(input, seps)

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
