# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.TargetRunner.SilentPrinter do
  @moduledoc false
  # Stand-in for `Benchee.Output.ProgressPrinter` so calling
  # `Benchee.Statistics.statistics/2` from outside the regular
  # `Benchee.run` flow doesn't print "Calculating statistics…" lines.
  # The runner's own summary printer handles user-facing output.
  def calculating_statistics(_), do: :ok
  def benchmarking(_, _, _, _), do: :ok
  def configuration_information(_), do: :ok
end

defmodule Awfy.TargetRunner do
  @moduledoc """
  Run a benchmark against a different (typically older) OTP than the
  one orchestrating from the host.

  The host project compiles and loads with whatever modern OTP/Elixir
  the runner asks for. When `AWFY_TARGET_ERL` points at a different
  `erl` binary, this module shells out to that VM with the
  pre-compiled target beams on its code path and runs the plain-Erlang
  harness `awfy_target_runner` (in `apps/awfy/src_target/`).

  ## Why shell out instead of using `:peer`?

  `:peer.start_link/1` accepts an `:exec` option that *is* the path to
  a different `erl`, so peer-with-exec is technically possible. We use
  `System.cmd/3` instead because:

    * The peer's stdio protocol assumes the controller and target
      speak the same External Term Format dialect. ETF has been very
      stable, but bugs have shipped (OTP 26's tuple compaction change,
      etc.) — staying in plain text avoids that whole class of issue.
    * Shelling out makes it trivial to swap the harness invocation
      without touching the runner. A future patch could replace the
      Erlang harness with anything that prints `Time_ns\\n` lines.
    * The once-per-benchmark fork cost (~30-50 ms on Linux) is paid
      *outside* the timed window — the harness times each iteration
      with `erlang:monotonic_time/1` after VM startup.

  ## How target beams get there

  `bin/install-otp-source.sh` and the Linux Dockerfile compile the
  benchmark suite's `apps/awfy/src/*.erl` plus the harness in
  `apps/awfy/src_target/*.erl` using the **target's** `erlc` and drop
  the resulting `.beam` files in a directory that gets mounted /
  passed in via `AWFY_TARGET_BEAMS`.

  Elixir benchmarks aren't compiled in this path (older OTPs may not
  have a compatible Elixir at all). On targets where Elixir benchmarks
  can run, the same dir holds `Elixir.Awfy.Benchmarks.*.beam` files
  produced by the target's `mix compile`; this module doesn't care
  which language a benchmark module came from.

  ## Configuration

    * `AWFY_TARGET_ERL`    — path to the target `erl` binary (required
      to enter target mode; absent means the host path is used).
    * `AWFY_TARGET_BEAMS`  — path to a dir of `.beam` files to load via
      `-pa`. May be a colon-separated list. Required when target mode
      is enabled.
  """

  @type ns :: non_neg_integer()

  @doc """
  Are we in target mode? True iff `AWFY_TARGET_ERL` is set.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: target_erl() != nil

  @doc """
  Run `Module:inner_benchmark_loop(inner_iter)` `iter_count` times on
  the target OTP. Returns the per-iteration times in nanoseconds.

  Raises if the target VM exits non-zero, or if any line of stdout
  isn't an integer.
  """
  @spec run_raw(module(), pos_integer(), pos_integer()) :: [ns]
  def run_raw(module, inner_iter, iter_count)
      when is_atom(module) and is_integer(inner_iter) and inner_iter >= 0 and
             is_integer(iter_count) and iter_count > 0 do
    erl = target_erl() || raise "AWFY_TARGET_ERL must be set to call TargetRunner.run_raw/3"
    beams = target_beams() || raise "AWFY_TARGET_BEAMS must be set to call TargetRunner.run_raw/3"

    eval =
      "awfy_target_runner:run_iters_io(#{erlang_atom(module)}, #{inner_iter}, #{iter_count})"

    pa_args = beams |> String.split(":", trim: true) |> Enum.flat_map(&["-pa", &1])

    args = ["-noshell"] ++ pa_args ++ ["-eval", eval, "-s", "init", "stop"]

    case System.cmd(erl, args, stderr_to_stdout: false) do
      {output, 0} -> parse_timings(output)
      {output, code} -> raise "target erl exited #{code}: #{output}"
    end
  end

  @doc """
  Run a full benchmark (one or more `{lang, module}` entries sharing
  one name) under target OTP and return a `%Benchee.Suite{}` whose
  scenarios already have computed statistics — same shape Benchee
  itself produces, so `Awfy.Compare.Data` doesn't need to know it
  came from this path.

  `time_seconds` and `warmup_seconds` mirror Benchee's `:time` and
  `:warmup` config: warmup samples are taken first and discarded;
  measurement runs to fill at least the requested wall-clock budget
  (estimated via a 3-iteration calibration pass per scenario).

  Elixir-language entries are skipped silently when the target's
  `_target_build` doesn't include `Elixir.*` beams, which is the
  expected state for OTP < 24. Returns `nil` for the suite when
  every entry was skipped.
  """
  @spec run_benchmark(String.t(), [{:erlang | :elixir, module()}], pos_integer(), keyword()) ::
          Benchee.Suite.t() | nil
  def run_benchmark(name, entries, inner_iter, opts) do
    time_seconds = Keyword.get(opts, :time, 5)
    warmup_seconds = Keyword.get(opts, :warmup, 1)

    scenarios =
      entries
      |> Enum.map(fn {lang, mod} -> build_scenario(name, lang, mod, inner_iter, time_seconds, warmup_seconds) end)
      |> Enum.reject(&is_nil/1)

    if scenarios == [] do
      nil
    else
      suite = %Benchee.Suite{
        scenarios: scenarios,
        configuration: %Benchee.Configuration{
          percentiles: [50, 99],
          # We pre-built the samples — Statistics just crunches them.
          exclude_outliers: false
        },
        system: %Benchee.System{
          elixir: System.version(),
          erlang: System.otp_release(),
          jit_enabled?: :erlang.system_info(:emu_flavor) == :jit,
          num_cores: System.schedulers_online(),
          os: elem(:os.type(), 1),
          available_memory: 0,
          cpu_speed: ""
        }
      }

      Benchee.Statistics.statistics(suite, Awfy.TargetRunner.SilentPrinter)
    end
  end

  defp build_scenario(name, lang, module, inner_iter, time_s, warmup_s) do
    sname = "#{name}/#{lang}"

    cond do
      # Elixir benchmarks need their own beams compiled by the target's
      # mix; if the build pipeline didn't produce them (older OTP, no
      # compatible Elixir), the load fails fast rather than churning
      # through a fork to discover it.
      lang == :elixir and not target_has_module?(module) ->
        IO.puts(:stderr, "[target] skipping #{sname} — module not available on target")
        nil

      true ->
        # Calibrate with 3 iterations to estimate per-iter cost, then
        # run enough iters to fill the warmup + time budget.
        cal = run_raw(module, inner_iter, 3)
        median_ns = median(cal)

        warmup_count = max(0, ceil_div(warmup_s * 1_000_000_000, median_ns))
        measure_count = max(3, ceil_div(time_s * 1_000_000_000, median_ns))

        all = run_raw(module, inner_iter, warmup_count + measure_count)
        samples = Enum.drop(all, warmup_count)

        %Benchee.Scenario{
          name: sname,
          job_name: sname,
          run_time_data: %Benchee.CollectionData{
            samples: samples,
            statistics: %Benchee.Statistics{}
          }
        }
    end
  end

  defp ceil_div(a, b) when b > 0, do: div(a + b - 1, b)
  defp ceil_div(_, _), do: 1

  defp median([]), do: 1_000_000

  defp median(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    if rem(n, 2) == 1, do: Enum.at(sorted, div(n, 2)), else: Enum.at(sorted, div(n, 2))
  end

  # Probe the target beams dir for a matching `.beam` file — cheap
  # filesystem check, avoids forking erl just to find out a module
  # doesn't exist.
  defp target_has_module?(module) do
    name = Atom.to_string(module) <> ".beam"

    target_beams()
    |> to_string()
    |> String.split(":", trim: true)
    |> Enum.any?(fn dir -> File.exists?(Path.join(dir, name)) end)
  end

  defp target_erl, do: System.get_env("AWFY_TARGET_ERL")
  defp target_beams, do: System.get_env("AWFY_TARGET_BEAMS")

  # Render a module atom in Erlang's externally-typeable form. The
  # benchmark modules are either `:awfy_bounce` style (no quoting
  # needed) or `Awfy.Benchmarks.Bounce` (Elixir → `'Elixir.…'`).
  defp erlang_atom(module) when is_atom(module) do
    s = Atom.to_string(module)

    cond do
      # Already-quoted (e.g. interactive testing): trust the caller.
      String.starts_with?(s, "'") -> s
      # `Elixir.Awfy.…` needs single quotes around the whole atom.
      String.starts_with?(s, "Elixir.") -> "'#{s}'"
      # All-lowercase erlangish atom: no quoting.
      :otherwise -> s
    end
  end

  @doc false
  @spec parse_timings(String.t()) :: [ns]
  def parse_timings(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Integer.parse(line) do
        {n, ""} when n >= 0 ->
          n

        _ ->
          raise "unexpected output line from target erl (not a non-negative integer): #{inspect(line)}"
      end
    end)
  end
end
