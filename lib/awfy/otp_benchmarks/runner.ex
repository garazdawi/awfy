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

    * `AWFY_NO_ISOLATION=1` → in-process (debug / doctest)
    * default (OTP ≥ 24)    → `Awfy.PeerRunner.run_mfa/4` per family

  Cross-OTP / bundle-target mode is not wired here yet — extended
  benchmarks ship inside `apps/otp_benchmarks/`, so the target
  erlc compiles them alongside the AWFY suite, but the bundle
  entry point still needs a sibling to `Awfy.TargetRunner` that
  knows about the scenario-list shape. Tracked under
  `PLAN/EXTENDED_BENCH_PLAN.md` step 8.
  """

  @type opts :: [
          benchee: keyword(),
          save_dir: Path.t() | nil,
          save_tag: String.t() | nil,
          benchmarks: [String.t()] | nil
        ]

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

  defp build_benchee_opts(name, opts) do
    base =
      Keyword.get(opts, :benchee, default_benchee_opts())
      |> Keyword.put_new(:time, 3)
      |> Keyword.put_new(:warmup, 1)

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
