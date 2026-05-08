# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.TargetRunner do
  @moduledoc """
  Target-side run script. Invoked by the host via `erl -s` against
  a target Elixir bundle in one of two argv shapes — AWFY (the
  legacy single-benchmark form) or OtpBenchmarks (multi-input
  family form). `main/0` reads `:init.get_plain_arguments/0`,
  dispatches on the leading flag, runs `Benchee.run/2`, and
  writes a `.benchee` file the host reads back via
  `:erlang.binary_to_term/1`.

  ## AWFY shape

      $TARGET/bin/erl -noshell \\
        -pa $BUNDLE/lib/*/ebin \\
        -s 'Elixir.Awfy.TargetRunner' main \\
        -extra <module> <inner_iter> <time_s> <warmup_s> <out_path>

  Five positional args:

  | position | name        | type    | meaning                                          |
  | -------- | ----------- | ------- | ------------------------------------------------ |
  | 1        | module      | atom    | Erlang or Elixir benchmark module name           |
  | 2        | inner_iter  | int     | inner iteration count passed to `module.benchmark/1` |
  | 3        | time        | seconds | Benchee `:time` budget (int or float)            |
  | 4        | warmup      | seconds | Benchee `:warmup` budget (int or float)          |
  | 5        | out         | path    | absolute path the `.benchee` file is written to  |

  ## OtpBenchmarks shape

      $TARGET/bin/erl -noshell \\
        -pa $BUNDLE/lib/*/ebin \\
        -s 'Elixir.Awfy.TargetRunner' main \\
        -extra --otp-benchmarks <family_module> <time_s> <warmup_s> <out_path>

  One leading flag + four positional args. The family module is an
  Elixir module implementing `OtpBenchmarks.Benchmark` (e.g.
  `Elixir.OtpBenchmarks.Benchmarks.Phash2`). Inputs come from
  `family.inputs/0` on the target VM — the family module's `.beam`
  must be on the `-pa` path (via `AWFY_TARGET_BEAMS` carrying
  `<prefix>/awfy_target/otp_benchmarks-0.1.0/ebin`).

  Setup / teardown go through Benchee's `:before_scenario` /
  `:after_scenario` hooks, mirroring the host-side
  `Awfy.OtpBenchmarks.Runner.do_run/2` flow. Saved `.benchee` has
  one scenario per input — the host reads it back identically to
  any peer-mode OtpBenchmarks run.

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

  Dispatches on the leading argv element:

    * `--otp-benchmarks` → multi-input family shape via `run_otp_family/1`.
    * anything else      → AWFY single-benchmark shape via `run/1`.
  """
  @spec main() :: no_return()
  def main do
    args = :init.get_plain_arguments() |> Enum.map(&List.to_string/1)

    case args do
      ["--otp-benchmarks" | rest] ->
        rest |> parse_otp_args() |> run_otp_family()

      _ ->
        args |> parse_args() |> run()
    end

    :init.stop()
  end

  @doc """
  Parse AWFY-shape argv (a list of strings) into a config map.
  Public so tests can exercise the contract without spinning up a
  target erl.
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

  @doc """
  Parse OtpBenchmarks-shape argv (after the leading
  `--otp-benchmarks` flag has been peeled off in `main/0`) into a
  config map. Public so tests can exercise the parsing without
  spinning up a target erl.
  """
  @spec parse_otp_args([String.t()]) :: %{
          family: atom(),
          time: number(),
          warmup: number(),
          out: String.t()
        }
  def parse_otp_args([family, time, warmup, out]) do
    %{
      family: String.to_atom(family),
      time: parse_seconds("time", time),
      warmup: parse_seconds("warmup", warmup),
      out: out
    }
  end

  def parse_otp_args(other) do
    raise ArgumentError,
          "expected 4 plain args after --otp-benchmarks " <>
            "(family time warmup out), got: " <> inspect(other)
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
      formatters: []
    )
    |> write_slim_suite(out)
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

  @doc """
  Run one OtpBenchmarks family on the target VM. Mirrors
  `Awfy.OtpBenchmarks.Runner.do_run/2` on the host: builds a single
  Benchee scenario keyed by the family's `name/0` and runs it
  across the inputs from `inputs/0`, with `setup/1` and
  `teardown/1` wired into Benchee's per-scenario hooks. Public so
  tests can drive the path with a stub family module.
  """
  @spec run_otp_family(map()) :: %Benchee.Suite{}
  def run_otp_family(%{family: family, time: time, warmup: warmup, out: out}) do
    Benchee.run(
      %{family.name() => fn input -> family.run(input) end},
      inputs: family.inputs(),
      before_scenario: fn raw -> family.setup(raw) end,
      after_scenario: fn state -> family.teardown(state) end,
      time: time,
      warmup: warmup,
      memory_time: 0,
      reduction_time: 0,
      print: [benchmarking: false, configuration: false, fast_warning: false],
      formatters: []
    )
    |> write_slim_suite(out)
  end

  # Drop raw `samples` lists from each scenario before writing the
  # `.benchee` file the host reads back via `binary_to_term/1`.
  # Mirrors `Awfy.SuiteSlim` in the runner project — kept inline
  # here because awfy_target_runner is intentionally not a path-dep
  # of the runner (per PLAN/TARGET_ELIXIR_RUNNER_PLAN.md decision
  # #10), so we can't share the helper. The two implementations are
  # tiny and stay trivially in sync.
  defp write_slim_suite(%Benchee.Suite{scenarios: scenarios} = suite, out) do
    slim = %{suite | scenarios: Enum.map(scenarios, &slim_scenario/1)}
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, :erlang.term_to_binary(slim))
    slim
  end

  defp slim_scenario(%Benchee.Scenario{} = s) do
    %{
      s
      | run_time_data: clear_samples(s.run_time_data),
        memory_usage_data: clear_samples(s.memory_usage_data),
        reductions_data: clear_samples(s.reductions_data)
    }
  end

  defp clear_samples(%Benchee.CollectionData{statistics: stats} = cd) do
    %{cd | samples: [], statistics: clear_outliers(stats)}
  end

  defp clear_samples(other), do: other

  defp clear_outliers(%Benchee.Statistics{} = stats), do: %{stats | outliers: []}
  defp clear_outliers(other), do: other
end
