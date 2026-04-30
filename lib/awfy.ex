defmodule Awfy do
  @moduledoc """
  AWFY benchmark suite ports for Erlang and Elixir.

  Two parallel ports of every benchmark, registered separately so the
  test harness can run both. Use `benchmarks/0` to list registered
  benchmarks; use `verify/1` to run one and check `verify_result/1`.
  """

  @doc """
  All registered benchmarks across both languages.

  Each entry is a tuple `{language, module}` where `language` is
  `:erlang` or `:elixir`.
  """
  def benchmarks do
    erlang_benchmarks() ++ elixir_benchmarks()
  end

  def erlang_benchmarks do
    for m <- [
          :awfy_bounce,
          :awfy_havlak,
          :awfy_json,
          :awfy_list,
          :awfy_mandelbrot,
          :awfy_nbody,
          :awfy_permute,
          :awfy_queens,
          :awfy_richards,
          :awfy_sieve,
          :awfy_storage,
          :awfy_towers
        ],
        do: {:erlang, m}
  end

  def elixir_benchmarks do
    for m <- [
          Awfy.Benchmarks.Bounce,
          Awfy.Benchmarks.Havlak,
          Awfy.Benchmarks.Json,
          Awfy.Benchmarks.List,
          Awfy.Benchmarks.Mandelbrot,
          Awfy.Benchmarks.NBody,
          Awfy.Benchmarks.Permute,
          Awfy.Benchmarks.Queens,
          Awfy.Benchmarks.Richards,
          Awfy.Benchmarks.Sieve,
          Awfy.Benchmarks.Storage,
          Awfy.Benchmarks.Towers
        ],
        do: {:elixir, m}
  end

  @doc """
  Run a benchmark's `inner_benchmark_loop(inner_iter)` and return the
  boolean result. Used by both the test harness and the runner.
  """
  def verify({:erlang, mod}, inner_iter) do
    mod.inner_benchmark_loop(inner_iter)
  end

  def verify({:elixir, mod}, inner_iter) do
    mod.inner_benchmark_loop(inner_iter)
  end

  @doc """
  Pretty name of a registered benchmark.

  Both Erlang's `name/0` (returns a charlist by Erlang convention) and
  Elixir's `name/0` (returns a binary) get normalized to a binary here
  so callers can compare them with `==`.
  """
  def name({:erlang, mod}), do: to_string(mod.name())
  def name({:elixir, mod}), do: to_string(mod.name())
end
