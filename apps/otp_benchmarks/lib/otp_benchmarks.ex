# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks do
  @moduledoc """
  Registry for BEAM-internal benchmark families. See
  `PLAN/EXTENDED_BENCH_PLAN.md` and `OtpBenchmarks.Benchmark`.

  Mirrors `Awfy.benchmarks/0` but returns a flat list of
  `OtpBenchmarks.Benchmark`-implementing modules — one per family.
  Each family expands to N Benchee scenarios at run time via the
  module's `inputs/0`.
  """

  @doc "All registered benchmark families, in display order."
  def benchmarks do
    [
      OtpBenchmarks.Benchmarks.Phash2,
      OtpBenchmarks.Benchmarks.Maps,
      OtpBenchmarks.Benchmarks.IolistSize,
      OtpBenchmarks.Benchmarks.Base64,
      OtpBenchmarks.Benchmarks.BinaryMatch,
      OtpBenchmarks.Benchmarks.Unicode
    ]
  end

  @doc "Look up a family by its `name/0` string. Returns the module or nil."
  def fetch_by_name(name) when is_binary(name) do
    Enum.find(benchmarks(), fn mod -> mod.name() == name end)
  end
end
