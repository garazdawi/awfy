# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.Base64Encode do
  @moduledoc """
  `:base64.encode/1` over binary inputs spanning the size range
  the implementation has different code paths for: small inputs
  (per-3-byte-group loop), medium (built-up iolist with periodic
  binary flush), large (NIF-accelerated chunked path). Sizes
  chosen at boundary multiples of 3 bytes so no padding overhead
  variance leaks into the timed window.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "base64_encode"

  def inputs do
    %{
      "n63" => :binary.copy(<<"abc">>, 21),
      "n3k" => :binary.copy(<<"abc">>, 1024),
      "n64k" => :binary.copy(<<"abc">>, 21845)
    }
  end

  def run(bin), do: :base64.encode(bin)
end
