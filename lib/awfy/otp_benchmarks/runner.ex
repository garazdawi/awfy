# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.OtpBenchmarks.Runner do
  @moduledoc """
  Runs an `OtpBenchmarks.Benchmark` family under Benchee.

  Mirrors `Awfy.BencheeRunner` in spirit but adapted to the
  OtpBenchmarks shape: one module = one Benchee run with N
  scenarios (one per `inputs/0` entry), saved to a single
  `.benchee` file named after the family (`phash2.benchee`).

  Execution-mode dispatch matches the AWFY runner:

    * `AWFY_TARGET_ERL` set → bundle-target shell-out via
      `Awfy.Runner.run_otp_family/3` (cross-OTP path; suite
      executed under the target erl, suite term shipped back via
      `binary_to_term`).
    * `AWFY_NO_ISOLATION=1` → in-process (debug / doctest)
    * default (OTP ≥ 24)    → `Awfy.PeerRunner.run_mfa/4` per family
  """

  @type opts :: [
          benchee: keyword(),
          save_dir: Path.t() | nil,
          save_tag: String.t() | nil,
          benchmarks: [String.t()] | nil
        ]

  # Per-family Benchee `:time` budgets — same calibration pattern
  # as `Awfy.BencheeRunner.@default_time`. Families dominated by
  # sub-microsecond inputs (phash2, ets) want more wall-clock time
  # so the *number* of samples climbs, even though the per-sample
  # *resolution* is capped by the hardware monotonic clock — on
  # Apple Silicon that floor is ~42 ns (24 MHz timer base), so
  # every BIF that returns in < 100 ns ends up bucketed at one
  # multiple of 42 ns. Calibration via `:time` doesn't fix the
  # floor; what it does is cut tail noise from intermittent OS
  # spikes by giving more samples to dilute. Mnesia / estone get
  # bumped time to compensate for high per-iteration cost yielding
  # very few raw samples at the default 3 s.
  #
  # CLI `--time` overrides this table uniformly; tests pin it as
  # the source of truth for per-family defaults.
  @default_time %{
    "phash2" => 5,
    "maps" => 3,
    "iolist_size" => 3,
    "base64" => 3,
    "binary_match" => 3,
    "unicode" => 3,
    "ets" => 5,
    "estone" => 5,
    "mnesia_tpcb" => 5
  }

  @default_warmup 1

  @doc """
  Default Benchee `:time` (seconds) for a registered family name.
  Falls back to 3 if the family isn't in the calibration table —
  surfaces in tests via `every_family_has_time_entry?/0`.
  """
  @spec time_for(String.t()) :: pos_integer()
  def time_for(name), do: Map.get(@default_time, name, 3)

  @doc """
  Run every registered benchmark family.

  Options:
    * `:benchmarks` — only run families whose `name/0` is in this list.
    * `:benchee`    — keyword list passed through to `Benchee.run/2`
      (e.g. `time:`, `warmup:`, `memory_time:`).
    * `:save_dir`   — directory to write `<family>.benchee` files into.
    * `:save_tag`   — tag attached to each save (typically the run label).
  """
  @spec run_all(opts()) :: :ok
  def run_all(opts \\ []) do
    families =
      OtpBenchmarks.benchmarks()
      |> filter_families(Keyword.get(opts, :benchmarks))

    Enum.each(families, fn mod -> run_one(mod, opts) end)
  end

  @doc "Run a single benchmark family by its module."
  @spec run_one(module(), opts()) :: :ok
  def run_one(mod, opts \\ []) when is_atom(mod) do
    name = mod.name()
    benchee_opts = build_benchee_opts(name, opts)
    save_path = save_path(name, opts)

    IO.puts("\n=== #{name} (#{map_size(mod.inputs())} scenarios) ===")

    cond do
      target_runner_enabled?() ->
        run_bundle(mod, benchee_opts, save_path)

      System.get_env("AWFY_NO_ISOLATION") == "1" ->
        suite = do_run(mod, benchee_opts)
        write_slim_suite(suite, save_path)

      true ->
        suite = Awfy.PeerRunner.run_mfa(__MODULE__, :do_run, [mod, benchee_opts], name)
        write_slim_suite(suite, save_path)
    end

    :ok
  end

  @doc false
  # Public so :peer.call/4 can dispatch by MFA — closures defined in
  # ExUnit modules don't deserialise on the peer (same reason
  # PeerRunner.run_mfa exists). The name_hint of the peer is the
  # family name so crash dumps identify which family blew up.
  #
  # Slims the suite before returning so the cross-pipe trip back to
  # the controller doesn't carry tens of MB of raw samples per
  # family — see `Awfy.SuiteSlim`.
  def do_run(mod, benchee_opts) do
    if not mod.supported?() do
      # Family declared itself unsupported on this OTP (e.g. a
      # BIF added in a later OTP minor than the target). Return
      # an empty suite rather than letting Benchee call
      # run/1 — Benchee aborts the whole VM via init terminating
      # on undef, taking the entire measurement run with it.
      IO.puts("\n[#{mod.name()}] unsupported on this OTP — skipping family")
      %Benchee.Suite{scenarios: [], configuration: %Benchee.Configuration{}}
    else
      do_run_supported(mod, benchee_opts)
    end
  end

  # Probe target: each Benchee sample should be at least this long
  # so the per-sample resolution is comfortably above the host's
  # monotonic-clock floor (~42 ns on Apple Silicon, ~10 ns on
  # Windows QPC, sub-ns on Linux). 100 µs gives ~3 decimal digits of
  # resolution against the worst-case 42 ns floor without making
  # individual samples slow enough to thin out the sample count below
  # ~1000 for any realistic per-call duration.
  @probe_target_ns 100_000

  # Powers of 10 cover everything from "one call already takes
  # 100 µs+" (batch=1) to "this is a single instruction" (batch=1M).
  # Probe stops at the first size whose timed pass crosses the target.
  @probe_batch_sizes [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]

  defp do_run_supported(mod, benchee_opts) do
    raw_inputs = mod.inputs()

    # Probe each input to find a batch factor. Setup state once for
    # the probe, then tear it down — Benchee re-runs setup via
    # before_scenario, which is the right boundary because state
    # like an ETS table accumulates writes during the probe and we
    # don't want that bleed-through to skew the timed run.
    #
    # Families that opt out via `batchable?/0 == false` skip the
    # probe entirely and run with batch=1 — see estone's moduledoc
    # for why it self-loops and can't tolerate outer batching.
    batchable = function_exported?(mod, :batchable?, 0) and mod.batchable?()

    batched_inputs =
      Map.new(raw_inputs, fn {name, raw} ->
        batch =
          if batchable do
            state = mod.setup(raw)
            b = probe_batch_factor(mod, state)
            mod.teardown(state)
            b
          else
            1
          end

        {name, {raw, batch}}
      end)

    benchee_opts =
      benchee_opts
      |> Keyword.put(:inputs, batched_inputs)
      |> Keyword.put(:before_scenario, fn {raw, batch} ->
        {mod.setup(raw), batch}
      end)
      |> Keyword.put(:after_scenario, fn {state, _batch} ->
        mod.teardown(state)
      end)

    %{mod.name() => fn {state, batch} -> run_batched(mod, state, batch) end}
    |> Benchee.run(benchee_opts)
    |> adjust_for_batching(batched_inputs)
    |> Awfy.SuiteSlim.slim()
  end

  # Find the smallest batch size whose total timed work exceeds the
  # probe target. Each candidate runs twice: a warmup pass to let JIT
  # compile any hot loop, then a timed pass. Falls through to the
  # largest candidate if no size hits the target (the workload is
  # genuinely tiny and bench-bound by Benchee's own per-sample
  # overhead — at that point batching even more wouldn't help).
  defp probe_batch_factor(mod, state) do
    Enum.reduce_while(@probe_batch_sizes, 1, fn batch, _acc ->
      # Warmup pass — JIT, cache, code-loading.
      Enum.each(1..batch, fn _ -> mod.run(state) end)
      start = :erlang.monotonic_time(:nanosecond)
      Enum.each(1..batch, fn _ -> mod.run(state) end)
      elapsed = :erlang.monotonic_time(:nanosecond) - start

      if elapsed >= @probe_target_ns do
        {:halt, batch}
      else
        {:cont, batch}
      end
    end)
  end

  defp run_batched(mod, state, 1), do: mod.run(state)

  defp run_batched(mod, state, batch) do
    Enum.each(1..batch, fn _ -> mod.run(state) end)
  end

  # Benchee sees one "sample" = one batch of N consecutive calls,
  # reported as `time_total = N × per_call`. To keep the saved median
  # / mean / percentiles directly comparable to non-batched
  # measurements (and across platforms that might pick different
  # batch factors), divide all time-domain stats by N. Sample-size is
  # scaled UP by N so it reflects the actual number of inner calls
  # measured (e.g. 4 000 batched samples × 250 = 1 000 000 calls).
  #
  # Note on stddev semantics: Benchee's σ is the stddev of the
  # *batched sums*. σ_total ≈ σ_per_call √N, so dividing by N gives
  # σ_per_call / √N — that's the standard error of the per-call mean,
  # exactly what a stability metric wants ("how much will the median
  # move on re-run?"). Tighter than the raw per-sample σ.
  defp adjust_for_batching(suite, batched_inputs) do
    scenarios =
      Enum.map(suite.scenarios, fn s ->
        batch =
          case s.input_name && Map.get(batched_inputs, s.input_name) do
            {_raw, b} -> b
            _ -> 1
          end

        if batch <= 1 do
          s
        else
          rtd = s.run_time_data
          stats = rtd.statistics

          divide = fn nil -> nil
                       v when is_number(v) -> v / batch
                  end

          new_stats =
            stats
            |> Map.update(:median, nil, divide)
            |> Map.update(:average, nil, divide)
            |> Map.update(:std_dev, nil, divide)
            |> Map.update(:minimum, nil, divide)
            |> Map.update(:maximum, nil, divide)
            |> Map.update(:mode, nil, fn
              nil -> nil
              v when is_number(v) -> v / batch
              vs when is_list(vs) -> Enum.map(vs, &(&1 / batch))
            end)
            |> Map.update(:percentiles, %{}, fn p ->
              Map.new(p || %{}, fn {k, v} ->
                {k, v && v / batch}
              end)
            end)
            |> Map.update(:sample_size, 0, fn n ->
              (n || 0) * batch
            end)

          %{s | run_time_data: %{rtd | statistics: new_stats}}
        end
      end)

    %{suite | scenarios: scenarios}
  end

  defp target_runner_enabled? do
    case System.get_env("AWFY_TARGET_ERL") do
      v when is_binary(v) and v != "" -> true
      _ -> false
    end
  end

  defp run_bundle(mod, benchee_opts, save_path) do
    bundle_dir = System.get_env("AWFY_TARGET_BUNDLE")

    if bundle_dir in [nil, ""] do
      Mix.raise(
        "AWFY_TARGET_BUNDLE must be set to the extracted target-Elixir " <>
          "bundle when AWFY_TARGET_ERL is set"
      )
    end

    extra_paths =
      case System.get_env("AWFY_TARGET_BEAMS") do
        nil -> []
        "" -> []
        v -> String.split(v, [":", ";"], trim: true)
      end

    time = Keyword.get(benchee_opts, :time)
    warmup = Keyword.get(benchee_opts, :warmup, 1)

    case Awfy.Runner.run_otp_family(bundle_dir, mod,
           time: time,
           warmup: warmup,
           extra_paths: extra_paths
         ) do
      {:ok, suite} ->
        print_target_summary(suite)
        write_slim_suite(suite, save_path)

      {:error, reason} ->
        IO.puts(
          :stderr,
          "[bundle] #{mod.name()} failed: #{inspect(reason)} — skipping family"
        )
    end
  end

  # See `Awfy.BencheeRunner.write_slim_suite/2` — same shape, kept
  # private here to avoid an awfy_target_runner-style cross-app
  # dep just for one helper.
  defp save_path(name, opts) do
    case Keyword.get(opts, :save_dir) do
      nil -> nil
      dir -> Path.join(dir, "#{name}.benchee")
    end
  end

  defp write_slim_suite(suite, nil), do: suite

  defp write_slim_suite(%Benchee.Suite{} = suite, path) do
    slim = Awfy.SuiteSlim.slim(suite)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(slim))
    slim
  end

  defp print_target_summary(%Benchee.Suite{scenarios: scenarios}) do
    IO.puts("\nName                        median       mean        σ      n")

    Enum.each(scenarios, fn s ->
      st = s.run_time_data.statistics
      label = scenario_label(s)

      :io.format("~-26s ~9.3f ms ~7.3f ms ~7.3f ~6B~n", [
        label,
        (st.median || 0) / 1_000_000,
        (st.average || 0) / 1_000_000,
        (st.std_dev || 0) / 1_000_000,
        st.sample_size || 0
      ])
    end)
  end

  defp scenario_label(%{name: name, input_name: input}) when is_binary(input),
    do: "#{name}/#{input}"

  defp scenario_label(%{name: name}), do: name

  defp build_benchee_opts(name, opts) do
    Keyword.get(opts, :benchee, default_benchee_opts())
    |> Keyword.put_new(:time, time_for(name))
    |> Keyword.put_new(:warmup, @default_warmup)
  end

  defp default_benchee_opts do
    [memory_time: 0, print: [fast_warning: false]]
  end

  defp filter_families(mods, nil), do: mods

  defp filter_families(mods, names) when is_list(names) do
    set = MapSet.new(names)
    Enum.filter(mods, fn mod -> MapSet.member?(set, mod.name()) end)
  end
end
