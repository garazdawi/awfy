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
    for m <- [:awfy_bounce], do: {:erlang, m}
  end

  def elixir_benchmarks do
    for m <- [Awfy.Benchmarks.Bounce], do: {:elixir, m}
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

  @doc "Pretty name of a registered benchmark."
  def name({:erlang, mod}), do: mod.name()
  def name({:elixir, mod}), do: mod.name()
end
