# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.BencheeRunner do
  @moduledoc """
  Runs registered AWFY benchmarks under [Benchee](https://hexdocs.pm/benchee).

  Each benchmark gets two scenarios — one calling the Erlang port, one
  the Elixir port — so Benchee compares them directly. Default
  `inner_iterations` per benchmark match AWFY's `rebench.conf` for
  realistic timings; override with the `:inner_iter` option.
  """

  # Default inner_iterations from upstream/rebench.conf. These match the
  # values the upstream project considers a "real" run of each benchmark.
  # For benchmarks where verify_result/2 depends on inner_iterations, the
  # default must match a value the verifier accepts.
  @default_inner_iter %{
    "Bounce" => 1500,
    "List" => 1500,
    "Mandelbrot" => 500,
    "NBody" => 250_000,
    "Permute" => 1000,
    "Queens" => 1000,
    "Sieve" => 3000,
    "Storage" => 1000,
    "Towers" => 600,
    "DeltaBlue" => 12_000,
    "Richards" => 100,
    "Json" => 100,
    "CD" => 250,
    "Havlak" => 1500
  }

  # Per-benchmark Benchee `:time` (seconds), calibrated from observed
  # medians so each scenario gets enough samples to dilute background-
  # noise spikes (Q6 in PLAN/BENCH_VERSIONS_PLAN.md).
  #
  # Stability check at uniform `time: 3` showed fast benchmarks
  # (Towers, List, Permute, Queens, Bounce, Mandelbrot) with CVs of
  # 4–55% across re-runs because a single 1-second OS spike could
  # dominate a 60-200ms-per-iter benchmark's measurement window. Slow
  # benchmarks (Sieve, DeltaBlue, Havlak, Json, CD, Richards) were at
  # 0.4–4% CV because the spike disappeared into a single multi-second
  # sample.
  #
  # Values below target ~50–100 samples for fast benchmarks; for slow
  # ones we accept ~3–5 samples since they're already stable. Total
  # measurement time per language ≈ 90s (was ~60s at uniform time: 3).
  @default_time %{
    "Bounce" => 8,
    "List" => 10,
    "Mandelbrot" => 8,
    "NBody" => 5,
    "Permute" => 10,
    "Queens" => 10,
    "Sieve" => 4,
    "Storage" => 8,
    "Towers" => 8,
    "Richards" => 5,
    "Json" => 6,
    "CD" => 5,
    "DeltaBlue" => 4,
    "Havlak" => 5
  }

  # Warmup is held at 1s for everything — the BEAM JIT settles fast,
  # and our run-1-vs-run-2 stability data didn't show a JIT-warmup
  # signature (run-1 was slow uniformly across both langs, suggesting
  # OS/system noise rather than JIT cold start).
  @default_warmup 1

  @type opts :: [
          inner_iter: pos_integer(),
          lang: :erlang | :elixir | :both,
          benchee: keyword(),
          benchmarks: [String.t()] | nil,
          save_dir: Path.t() | nil,
          save_tag: String.t() | nil,
          skip: [{:erlang | :elixir, module()}]
        ]

  @doc """
  Run every registered benchmark under Benchee.

  Options:
    * `:inner_iter` — override the default inner_iterations.
    * `:lang` — `:erlang`, `:elixir`, or `:both` (default).
    * `:benchee` — keyword list passed through to `Benchee.run/2`.
    * `:benchmarks` — only run benchmarks whose name is in this list.
    * `:save_dir` — directory to save `<name>.benchee` files into. When
      set, BencheeRunner adds a `save: [path:, tag:]` entry to the
      Benchee opts per benchmark. Pairs with `:save_tag`.
    * `:save_tag` — tag attached to each save (typically the run label).
    * `:skip` — list of `{lang, mod}` tuples to omit from the timing pass.
      Used by the Mix.Tasks.Awfy.Measure verify-then-time flow to skip
      ports that failed verification without aborting the whole run.
  """
  @spec run_all(opts()) :: :ok
  def run_all(opts \\ []) do
    skip = MapSet.new(Keyword.get(opts, :skip, []))
    bench_filter = Keyword.get(opts, :benchmarks, nil)

    by_name =
      Awfy.benchmarks()
      |> filter_lang(Keyword.get(opts, :lang, :both))
      |> Enum.reject(&MapSet.member?(skip, &1))
      |> filter_benchmarks(bench_filter)
      |> Enum.group_by(fn entry -> Awfy.name(entry) end)

    Enum.each(Map.keys(by_name) |> Enum.sort(), fn name ->
      run_one(name, by_name[name], opts)
    end)
  end

  @doc """
  Run a single benchmark by name (e.g. `"Bounce"`) under Benchee.
  """
  @spec run(String.t(), opts()) :: :ok
  def run(name, opts \\ []) do
    entries =
      Awfy.benchmarks()
      |> filter_lang(Keyword.get(opts, :lang, :both))
      |> Enum.filter(fn entry -> Awfy.name(entry) == name end)

    case entries do
      [] -> raise ArgumentError, "no benchmark named #{inspect(name)} registered"
      _ -> run_one(name, entries, opts)
    end
  end

  @doc """
  Default inner_iterations for a registered benchmark name.
  """
  @spec inner_iter_for(String.t()) :: pos_integer()
  def inner_iter_for(name), do: default_inner_iter(name)

  @doc """
  Default Benchee `:time` (seconds) for a registered benchmark name.
  """
  @spec time_for(String.t()) :: pos_integer()
  def time_for(name), do: Map.fetch!(@default_time, name)

  defp run_one(name, entries, opts) do
    inner_iter = Keyword.get(opts, :inner_iter, default_inner_iter(name))
    base_opts = Keyword.get(opts, :benchee, default_benchee_opts())

    # Per-benchmark time/warmup defaults — only applied when the caller
    # hasn't set those keys explicitly. A `--time` flag at the CLI
    # therefore overrides the per-benchmark defaults uniformly across
    # all benchmarks in the run, which is what users want when chasing
    # publication-quality numbers ("just measure everything for 30s").
    base_opts = Keyword.put_new(base_opts, :time, time_for(name))
    base_opts = Keyword.put_new(base_opts, :warmup, @default_warmup)

    benchee_opts = maybe_add_save(base_opts, name, opts)

    IO.puts("\n=== #{name} (inner_iter=#{inner_iter}) ===")

    # Three execution modes, in priority order:
    #
    #   1. Target mode (`AWFY_TARGET_ERL` set) — measure under a
    #      different OTP than the host orchestrator. The benchee Suite
    #      is built by Awfy.TargetRunner from raw timings collected
    #      via shell-out to the target erl.
    #   2. In-process (`AWFY_NO_ISOLATION=1`) — for debugging and
    #      doctests, where wrapping in a peer adds nothing.
    #   3. Isolated peer (default) — every benchmark runs in a fresh
    #      same-OTP peer per ISOLATION_POLICY.md.
    cond do
      Awfy.TargetRunner.enabled?() ->
        run_target(name, entries, inner_iter, benchee_opts)

      System.get_env("AWFY_NO_ISOLATION") == "1" ->
        run_in_process(name, entries, inner_iter, benchee_opts)

      true ->
        run_isolated(name, entries, inner_iter, benchee_opts)
    end

    :ok
  end

  defp run_target(name, entries, inner_iter, benchee_opts) do
    case Awfy.TargetRunner.run_benchmark(name, entries, inner_iter, benchee_opts) do
      nil ->
        IO.puts(:stderr, "[target] no compatible scenarios for #{name}, skipping")

      %Benchee.Suite{} = suite ->
        print_target_summary(suite)

        case Keyword.get(benchee_opts, :save) do
          nil ->
            :ok

          save_opts ->
            path = save_opts |> Keyword.fetch!(:path) |> to_string()
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, :erlang.term_to_binary(suite))
        end
    end
  end

  defp print_target_summary(%Benchee.Suite{scenarios: scenarios}) do
    IO.puts("\nName                        median       mean        σ      n")

    Enum.each(scenarios, fn s ->
      st = s.run_time_data.statistics
      :io.format("~-26s ~9.3f ms ~7.3f ms ~7.3f ~6B~n", [
        s.name,
        (st.median || 0) / 1_000_000,
        (st.average || 0) / 1_000_000,
        (st.std_dev || 0) / 1_000_000,
        st.sample_size || 0
      ])
    end)
  end

  defp run_in_process(name, entries, inner_iter, benchee_opts) do
    scenarios =
      Map.new(entries, fn {lang, mod} ->
        {"#{name}/#{lang}", fn -> run_scenario({lang, mod}, inner_iter) end}
      end)

    Benchee.run(scenarios, benchee_opts)
  end

  defp run_isolated(name, entries, inner_iter, benchee_opts) do
    # Closure body uses only public `Awfy.verify/2` so the cross-node
    # RPC doesn't depend on internal-function dispatch surviving the
    # serialise/deserialise round-trip. (It does in practice when the
    # same .beam is loaded both sides via `-pa`, but using public
    # functions keeps the closure trivially safe to RPC.)
    Awfy.PeerRunner.run(
      fn ->
        scenarios =
          Map.new(entries, fn {lang, _mod} = entry ->
            {"#{name}/#{lang}",
             fn ->
               case Awfy.verify(entry, inner_iter) do
                 true ->
                   :ok

                 false ->
                   raise "benchmark #{Awfy.name(entry)} produced an incorrect result"
               end
             end}
          end)

        Benchee.run(scenarios, benchee_opts)
      end,
      name
    )
  end

  defp maybe_add_save(opts, name, run_opts) do
    case Keyword.get(run_opts, :save_dir) do
      nil ->
        opts

      dir ->
        tag = Keyword.get(run_opts, :save_tag, "")
        path = Path.join(dir, "#{name}.benchee")
        Keyword.put(opts, :save, path: path, tag: tag)
    end
  end

  defp filter_benchmarks(entries, nil), do: entries

  defp filter_benchmarks(entries, names) when is_list(names) do
    set = MapSet.new(names)
    Enum.filter(entries, fn entry -> MapSet.member?(set, Awfy.name(entry)) end)
  end

  defp run_scenario(entry, inner_iter) do
    case Awfy.verify(entry, inner_iter) do
      true ->
        :ok

      false ->
        raise "benchmark #{Awfy.name(entry)} produced an incorrect result"
    end
  end

  defp filter_lang(entries, :both), do: entries
  defp filter_lang(entries, lang), do: Enum.filter(entries, fn {l, _} -> l == lang end)

  defp default_inner_iter(name) do
    Map.fetch!(@default_inner_iter, name)
  end

  defp default_benchee_opts do
    # No :time / :warmup here — those default to per-benchmark values
    # in run_one when the caller hasn't set them explicitly.
    [
      memory_time: 0,
      print: [fast_warning: false]
    ]
  end
end
