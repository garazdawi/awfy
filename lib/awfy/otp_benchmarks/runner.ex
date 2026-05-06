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
    "crypto_aead" => 3,
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

    IO.puts("\n=== #{name} (#{map_size(mod.inputs())} scenarios) ===")

    cond do
      target_runner_enabled?() ->
        run_bundle(mod, benchee_opts)

      System.get_env("AWFY_NO_ISOLATION") == "1" ->
        do_run(mod, benchee_opts)

      true ->
        Awfy.PeerRunner.run_mfa(__MODULE__, :do_run, [mod, benchee_opts], name)
    end

    :ok
  end

  @doc false
  # Public so :peer.call/4 can dispatch by MFA — closures defined in
  # ExUnit modules don't deserialise on the peer (same reason
  # PeerRunner.run_mfa exists). The name_hint of the peer is the
  # family name so crash dumps identify which family blew up.
  def do_run(mod, benchee_opts) do
    inputs = mod.inputs()

    # Wire setup / teardown through Benchee's per-scenario hooks. The
    # default behaviour-provided setup/1 is identity, so for static
    # inputs (phash2) the hooks add zero overhead — Benchee skips
    # before_scenario invocation entirely when the closure is the
    # identity function (it doesn't, but the cost is one fun call
    # per scenario, well outside the timed window).
    benchee_opts =
      benchee_opts
      |> Keyword.put(:inputs, inputs)
      |> Keyword.put(:before_scenario, fn raw -> mod.setup(raw) end)
      |> Keyword.put(:after_scenario, fn state -> mod.teardown(state) end)

    Benchee.run(%{mod.name() => fn input -> mod.run(input) end}, benchee_opts)
  end

  defp target_runner_enabled? do
    case System.get_env("AWFY_TARGET_ERL") do
      v when is_binary(v) and v != "" -> true
      _ -> false
    end
  end

  defp run_bundle(mod, benchee_opts) do
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
        maybe_save_suite(suite, benchee_opts)

      {:error, reason} ->
        IO.puts(
          :stderr,
          "[bundle] #{mod.name()} failed: #{inspect(reason)} — skipping family"
        )
    end
  end

  # Bundle's TargetRunner already wrote a `.benchee` to its tmp out
  # path inside `Awfy.Runner.run_otp_family`; the host received the
  # decoded suite struct. If the caller asked us to save (via
  # `:save_dir` → benchee_opts.save), copy the suite to that path
  # using the standard term_to_binary shape — same dance the AWFY
  # bundle path does in `Awfy.BencheeRunner.run_bundle`.
  defp maybe_save_suite(suite, benchee_opts) do
    case Keyword.get(benchee_opts, :save) do
      nil ->
        :ok

      opts ->
        path = opts |> Keyword.fetch!(:path) |> to_string()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, :erlang.term_to_binary(suite))
    end
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
    base =
      Keyword.get(opts, :benchee, default_benchee_opts())
      |> Keyword.put_new(:time, time_for(name))
      |> Keyword.put_new(:warmup, @default_warmup)

    case Keyword.get(opts, :save_dir) do
      nil ->
        base

      dir ->
        tag = Keyword.get(opts, :save_tag, "")
        path = Path.join(dir, "#{name}.benchee")
        Keyword.put(base, :save, path: path, tag: tag)
    end
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
