# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.Benchee do
  @shortdoc "Run AWFY benchmarks under Benchee"
  @moduledoc """
  Run AWFY benchmarks under Benchee.

  ## Usage

      mix awfy.benchee                   # all benchmarks, both languages
      mix awfy.benchee Bounce            # one benchmark, both languages
      mix awfy.benchee --lang erlang     # all benchmarks, Erlang only
      mix awfy.benchee Bounce --lang elixir
      mix awfy.benchee Bounce --inner-iter 100

  ## Options

    * `--lang LANG` — `erlang`, `elixir`, or `both` (default).
    * `--inner-iter N` — override default `inner_iterations` for the run.
    * `--time SECONDS` — Benchee measurement time per scenario (default 3).
    * `--warmup SECONDS` — Benchee warmup time per scenario (default 1).
  """

  use Mix.Task

  @switches [
    lang: :string,
    inner_iter: :integer,
    time: :integer,
    warmup: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    Mix.Task.run("compile")

    runner_opts =
      [
        lang: opts[:lang] |> parse_lang(),
        benchee: benchee_opts(opts)
      ]
      |> maybe_put(:inner_iter, opts[:inner_iter])

    case args do
      [] -> Awfy.BencheeRunner.run_all(runner_opts)
      [name] -> Awfy.BencheeRunner.run(name, runner_opts)
      _ -> Mix.raise("expected at most one benchmark name argument")
    end
  end

  defp parse_lang(nil), do: :both
  defp parse_lang("both"), do: :both
  defp parse_lang("erlang"), do: :erlang
  defp parse_lang("elixir"), do: :elixir
  defp parse_lang(other), do: Mix.raise("--lang must be erlang|elixir|both, got #{other}")

  defp benchee_opts(opts) do
    [
      time: opts[:time] || 3,
      warmup: opts[:warmup] || 1,
      memory_time: 0,
      print: [fast_warning: false]
    ]
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)
end
