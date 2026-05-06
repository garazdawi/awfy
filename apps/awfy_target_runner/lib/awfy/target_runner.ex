# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.TargetRunner do
  @moduledoc """
  Target-side run script. Invoked by `Awfy.Runner` on the host via
  `erl -s` against a target Elixir bundle:

      $TARGET/bin/erl -noshell \\
        -pa $BUNDLE/lib/*/ebin \\
        -s 'Elixir.Awfy.TargetRunner' main \\
        -extra <module> <inner_iter> <time_s> <warmup_s> <out_path>

  `main/0` reads its config from `:init.get_plain_arguments/0`,
  invokes `Benchee.run/2` against the named benchmark module, and
  writes a `.benchee` file at `<out_path>` that the host's
  `Awfy.Compare.Data.load/1` reads back without further conversion.

  ## Argv contract

  Five positional args:

  | position | name        | type    | meaning                                          |
  | -------- | ----------- | ------- | ------------------------------------------------ |
  | 1        | module      | atom    | Erlang or Elixir benchmark module name           |
  | 2        | inner_iter  | int     | inner iteration count passed to `module.benchmark/1` |
  | 3        | time        | seconds | Benchee `:time` budget (int or float)            |
  | 4        | warmup      | seconds | Benchee `:warmup` budget (int or float)          |
  | 5        | out         | path    | absolute path the `.benchee` file is written to  |

  The benchmark module must export `benchmark/1` taking the inner
  iteration count. For Erlang benchmarks (atom `:bounce`) that
  resolves to `bounce:benchmark(InnerIter)`; for Elixir benchmarks
  (atom `Bounce`) it resolves to `Bounce.benchmark(inner_iter)`.

  ## Why `main/0` reads `:init.get_plain_arguments/0`

  `erl -s Mod Fun atom1 atom2` calls `Mod:Fun([atom1, atom2])` —
  args become atoms. Atoms can't carry a benchmark module name
  whose value also needs to be a module atom (we'd need the
  literal string back to resolve it cleanly), and integers/paths
  don't survive the atom round-trip.

  `-extra` (or its synonym `--`) routes everything after it into
  `:init.get_plain_arguments/0` as a list of charlists,
  unmodified. We round-trip those through `List.to_string/1`
  (Appendix E: charlists on OTP 20, would be binaries on 21+ —
  `List.to_string/1` handles both).
  """

  @doc """
  Entry point invoked by `erl -s 'Elixir.Awfy.TargetRunner' main`.
  """
  @spec main() :: no_return()
  def main do
    :init.get_plain_arguments()
    |> Enum.map(&List.to_string/1)
    |> parse_args()
    |> run()

    :init.stop()
  end

  @doc """
  Parse argv (a list of strings) into a config map. Public so
  tests can exercise the contract without spinning up a target erl.
  """
  @spec parse_args([String.t()]) :: %{
          module: atom(),
          inner_iter: pos_integer(),
          time: number(),
          warmup: number(),
          out: String.t()
        }
  def parse_args([module, inner_iter, time, warmup, out]) do
    %{
      module: String.to_atom(module),
      inner_iter: String.to_integer(inner_iter),
      time: parse_seconds("time", time),
      warmup: parse_seconds("warmup", warmup),
      out: out
    }
  end

  def parse_args(other) do
    raise ArgumentError,
          "expected 5 plain args (module inner_iter time warmup out), got: " <>
            inspect(other)
  end

  defp parse_seconds(field, raw) do
    case Integer.parse(raw) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(raw) do
          {f, ""} ->
            f

          _ ->
            raise ArgumentError, "#{field}: expected number of seconds, got #{inspect(raw)}"
        end
    end
  end

  @doc """
  Run one Benchee invocation against the configured benchmark
  module. Public so tests can drive it with a stub benchmark.
  """
  @spec run(map()) :: %Benchee.Suite{}
  def run(%{module: module, inner_iter: inner_iter, time: time, warmup: warmup, out: out}) do
    label = benchmark_label(module)

    Benchee.run(
      %{label => bench_fn(module, inner_iter)},
      time: time,
      warmup: warmup,
      memory_time: 0,
      reduction_time: 0,
      # No console output — host scrapes the `.benchee` file.
      print: [benchmarking: false, configuration: false, fast_warning: false],
      formatters: [],
      save: [path: out, tag: "target"]
    )
  end

  # Benchee 1.5 keys the suite by job name; we use the module's
  # canonical string form. Erlang module atoms (`:bounce`) render
  # as "bounce"; Elixir module atoms (`Bounce`) render as "Bounce"
  # (without the `Elixir.` prefix) via `inspect/1`.
  defp benchmark_label(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      erlang -> erlang
    end
  end

  defp bench_fn(module, inner_iter) do
    fn -> module.benchmark(inner_iter) end
  end
end
