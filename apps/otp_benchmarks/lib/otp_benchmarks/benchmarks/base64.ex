# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Base64 do
  @moduledoc """
  `:base64` BIF group — encode, decode, and the RFC-2045 MIME
  decode variant. All in one family with op-tagged inputs so the
  dashboard renders them on one page; size-suffixed inputs keep
  the small-input / chunked-NIF code paths visible.

    * `encode_*`     — `:base64.encode/1` over 63 B / 3 KB / 64 KB
                       binaries; sizes are exact multiples of 3 so
                       padding overhead doesn't leak into the
                       timed window.
    * `decode_*`     — `:base64.decode/1`, mirror of the above.
                       Setup pre-encodes once per scenario so the
                       timed loop is decode-only.
    * `mime_decode_*`— `:base64.mime_decode/1`, the RFC-2045-aware
                       variant that has to skip whitespace + CRLF
                       every 76 chars. Setup interleaves the
                       linebreaks so the per-line skip cost is
                       load-bearing.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "base64"

  def inputs do
    %{
      "encode_n63" => {:encode, 63},
      "encode_n3k" => {:encode, 3 * 1024},
      "encode_n64k" => {:encode, 64 * 1024},
      "decode_n63" => {:decode, 63},
      "decode_n3k" => {:decode, 3 * 1024},
      "decode_n64k" => {:decode, 64 * 1024},
      "mime_decode_n3k" => {:mime_decode, 3 * 1024},
      "mime_decode_n64k" => {:mime_decode, 64 * 1024}
    }
  end

  def setup({:encode, byte_count}), do: {:encode, raw(byte_count)}
  def setup({:decode, byte_count}), do: {:decode, :base64.encode(raw(byte_count))}

  def setup({:mime_decode, byte_count}) do
    encoded = :base64.encode(raw(byte_count))
    {:mime_decode, chunks_of_76(encoded)}
  end

  def run({:encode, bin}), do: :base64.encode(bin)
  def run({:decode, b64}), do: :base64.decode(b64)
  def run({:mime_decode, b64}), do: :base64.mime_decode(b64)

  defp raw(byte_count), do: :binary.copy(<<"abc">>, div(byte_count, 3))

  # RFC 2045 line length is 76 characters; insert CRLF every 76 to
  # mirror real-world MIME bodies. The MIME decoder's whitespace-
  # skip path runs once per linebreak, so this is what makes the
  # mime_decode benchmark meaningfully different from the strict
  # decode path.
  defp chunks_of_76(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_every(76)
    |> Enum.map(&:erlang.list_to_binary/1)
    |> Enum.intersperse(<<"\r\n">>)
    |> :erlang.iolist_to_binary()
  end
end
