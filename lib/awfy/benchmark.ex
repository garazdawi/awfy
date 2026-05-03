# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Benchmark do
  @moduledoc """
  Behaviour for AWFY benchmark modules in Elixir.

  A benchmark implements either:
    * `benchmark/0` + `verify_result/1` — the default `inner_benchmark_loop/1`
      runs benchmark + verify_result the requested number of times.
    * `inner_benchmark_loop/1` directly — when verification depends on
      the inner_iterations value (Mandelbrot, NBody, Havlak).
  """

  @callback inner_benchmark_loop(inner_iter :: non_neg_integer()) :: boolean()
  @callback name() :: String.t()

  defmacro __using__(_) do
    quote do
      @behaviour Awfy.Benchmark

      def inner_benchmark_loop(0), do: true

      def inner_benchmark_loop(n) when n > 0 do
        if verify_result(benchmark()) do
          inner_benchmark_loop(n - 1)
        else
          false
        end
      end

      defoverridable inner_benchmark_loop: 1
    end
  end
end
