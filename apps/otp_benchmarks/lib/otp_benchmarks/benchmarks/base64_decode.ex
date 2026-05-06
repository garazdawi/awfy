# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Base64Decode do
  @moduledoc """
  `:base64.decode/1` — the inverse of `Base64Encode`. Same size
  ladder, same code-path coverage. Inputs are pre-encoded once
  per scenario so the timed loop measures only decode.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "base64_decode"

  def inputs do
    %{
      "n63" => 63,
      "n3k" => 3 * 1024,
      "n64k" => 64 * 1024
    }
  end

  def setup(byte_count) do
    raw = :binary.copy(<<"abc">>, div(byte_count, 3))
    :base64.encode(raw)
  end

  def run(b64), do: :base64.decode(b64)
end
