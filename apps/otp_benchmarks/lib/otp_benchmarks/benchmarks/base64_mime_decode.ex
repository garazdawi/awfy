# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Base64MimeDecode do
  @moduledoc """
  `:base64.mime_decode/1` — RFC 2045's variant that has to skip
  whitespace and linebreaks before each decode step. Different
  hot path from the strict decoder; matters for email and
  HTTP-multipart processing.

  Inputs include the 76-column linebreaks that the MIME spec
  mandates so the decoder pays its real per-line skip cost.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "base64_mime_decode"

  def inputs do
    %{
      "n3k" => 3 * 1024,
      "n64k" => 64 * 1024
    }
  end

  def setup(byte_count) do
    raw = :binary.copy(<<"abc">>, div(byte_count, 3))
    encoded = :base64.encode(raw)
    chunks_of_76(encoded)
  end

  def run(b64), do: :base64.mime_decode(b64)

  # RFC 2045 line length is 76 characters; insert CRLF every 76 to
  # mirror real-world MIME bodies. The MIME decoder's whitespace-
  # skip path runs once per linebreak, so this is what makes the
  # benchmark meaningfully different from the strict decode path.
  defp chunks_of_76(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_every(76)
    |> Enum.map(&:erlang.list_to_binary/1)
    |> Enum.intersperse(<<"\r\n">>)
    |> :erlang.iolist_to_binary()
  end
end
