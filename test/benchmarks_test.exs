# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.Benchmarks do
  @moduledoc """
  Smoke test: every registered benchmark runs `inner_benchmark_loop(1)`
  and produces a passing `verify_result/1`. This is the AWFY equivalent
  of the upstream `test.conf` rebench profile (iterations=1, verifies
  output).

  Tests are dynamically generated, one per benchmark, so a failure
  points clearly at which port (Erlang or Elixir) and which benchmark
  is wrong.
  """

  use ExUnit.Case, async: true

  for {lang, mod} <- Awfy.benchmarks() do
    inner_iter = Awfy.test_inner_iter({lang, mod})
    test_name = "#{lang} / #{Awfy.name({lang, mod})} passes verify_result with inner_iter=#{inner_iter}"
    @lang lang
    @mod mod
    @inner_iter inner_iter

    test test_name do
      assert Awfy.verify({@lang, @mod}, @inner_iter),
             "#{@lang} benchmark #{inspect(@mod)} did not produce the expected result"
    end
  end
end
