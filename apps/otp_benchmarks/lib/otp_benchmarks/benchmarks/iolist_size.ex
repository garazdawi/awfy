# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.Benchmarks.IolistSize do
  @moduledoc """
  `:erlang.iolist_size/1` across the regimes its implementation
  splits into:

    * **shallow** — flat list of small binaries; iterates once,
      summing each binary's byte_size. Tight loop, integer-only
      arithmetic.
    * **deep** — heavily-nested list (depth 1000); exercises the
      stack management on the BIF's recursive descent.
    * **huge** — large iolist (~16 MB) that crosses the BIF's
      reduction budget and trap-yields to the scheduler. The
      yield path was rewritten in OTP 21; regressions there are
      load-bearing for any code path producing big iolists
      (HTTP response assembly, file IO, …).

  Inputs are static and shared across iterations: `iolist_size/1`
  has no input-dependent caching, so re-measuring the same iolist
  measures the per-call cost we care about.
  """

  use OtpBenchmarks.Benchmark

  def name, do: "iolist_size"

  def inputs do
    %{
      "shallow_1k" => shallow(1000),
      "deep_1k" => deep(1000),
      "huge_16mb" => huge(16 * 1024 * 1024)
    }
  end

  def run(iolist), do: :erlang.iolist_size(iolist)

  # 1000 disjoint 8-byte binaries in a flat list.
  defp shallow(n) do
    chunk = <<"abcdefgh">>
    Enum.map(1..n, fn _ -> chunk end)
  end

  # Nested wrap of depth N around a single 8-byte chunk: [[[…[<<"abcdefgh">>]…]]].
  defp deep(0), do: <<"abcdefgh">>
  defp deep(n) when n > 0, do: [deep(n - 1)]

  # One ~size-byte binary wrapped in a single-element list — small
  # enough to build at module-load but large enough that
  # iolist_size traps at least once on its scan.
  defp huge(size_bytes) do
    [:binary.copy(<<"x">>, size_bytes)]
  end
end
