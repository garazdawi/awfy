# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.MeasureXmpp do
  @shortdoc "Run one MongooseIM + Amoc application-bench scenario, save .benchee"
  @moduledoc """
  Run a single XMPP application-bench scenario end-to-end against a
  named topology, write the resulting `%Benchee.Suite{}` to a
  run-dir under `results/`, and a minimal `meta.json` next to it so
  the existing dashboard discovery (`Awfy.Compare.Data`) can pick
  the row up.

  ## Usage

      mix awfy.measure_xmpp                                       # dynamic_domains_pm on :local
      mix awfy.measure_xmpp --scenario dynamic_domains_pm
      mix awfy.measure_xmpp --topology local
      mix awfy.measure_xmpp --label before-mongoose-uplift
      mix awfy.measure_xmpp --out results

  Docker must already be callable on this host before invoking this
  task. On macOS that typically means `colima start` (or run via
  `bin/measure-xmpp.sh`, which sources `bin/ensure-docker.sh` to do
  it automatically and tears it down on exit). On Linux the host is
  expected to already provide Docker.

  See `PLAN/MONGOOSEIM_BENCH_PLAN.md` for the broader design.
  """

  use Mix.Task

  alias Awfy.SuiteSlim
  alias Awfy.Xmpp.Runner

  @switches [
    scenario: :string,
    topology: :string,
    label: :string,
    out: :string,
    no_clobber: :boolean,
    dry_run: :boolean
  ]

  @default_scenario "dynamic_domains_pm"
  @default_topology "local"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    scenario = opts[:scenario] || @default_scenario
    topology = parse_topology(opts[:topology] || @default_topology)

    # Dry-run mode: print the .benchee filename this task WOULD
    # produce, then exit. Mirrors the same hook on `mix awfy.measure`.
    # Switch to Mix.Shell.Quiet first so any path-dep auto-compile
    # mix triggers while loading our task's module references
    # doesn't leak `==> <dep>` / `Generated <dep> app` lines into
    # the benchmark-name-per-line stdout the caller (the canonical
    # step in bench.yml) parses.
    if opts[:dry_run] do
      Mix.shell(Mix.Shell.Quiet)
      IO.puts(scenario)
      System.halt(0)
    end

    Mix.Task.run("compile", [])

    {:ok, ctx, dir} = Awfy.Measure.Setup.prepare(opts, :xmpp)

    Mix.shell().info("=== xmpp bench: #{scenario} on #{topology} ===")

    case Runner.run(scenario, topology) do
      {:ok, %{throughput: thr, cpu_pct: cpu, mem_mb: mem, suite: suite, config: config}} ->
        save_path = Path.join(dir, "#{scenario}.benchee")
        write_suite(save_path, suite)

        write_meta(dir, %{
          ctx: ctx,
          scenario: scenario,
          topology: topology,
          config: config,
          throughput: thr,
          cpu_pct: cpu,
          mem_mb: mem
        })

        Mix.shell().info(
          "\nWrote #{save_path} " <>
            "(cpu median #{format_median(suite, "xmpp_cpu/erlang")}%, " <>
            "mem median #{format_median(suite, "xmpp_mem/erlang")} MB, " <>
            "throughput median #{format_throughput(suite, "xmpp_speed/erlang")} msg/s)"
        )

      {:error, reason} ->
        Mix.raise("xmpp bench run failed: #{inspect(reason)}")
    end
  end

  defp parse_topology("local"), do: :local
  defp parse_topology("aws_clt"), do: :aws_clt
  defp parse_topology(other), do: Mix.raise("unknown --topology: #{inspect(other)}")

  defp write_suite(path, suite) do
    slim = slim_suite(suite)
    File.write!(path, :erlang.term_to_binary(slim))
  end

  # The runner builds the suite via `Awfy.AppBench.Result.build/3`,
  # which constructs Benchee maps directly rather than via the struct
  # constructors. SuiteSlim.slim/1 pattern-matches on the real structs,
  # so route through it only when Benchee is loaded; otherwise the
  # raw map is already slim by construction (no per-sample list past
  # the windowed throughput series, which we *do* want to keep).
  defp slim_suite(suite) do
    if Code.ensure_loaded?(Benchee.Suite) do
      SuiteSlim.slim(suite)
    else
      suite
    end
  end

  # Throughput scenarios store period-ns in median (lower=faster); we
  # invert back to msg/s for the human-readable end-of-run summary.
  defp format_throughput(suite, suffix) do
    case find_scenario_median(suite, suffix) do
      median when is_number(median) and median > 0 ->
        :erlang.float_to_binary(1_000_000_000 / median, decimals: 1)

      _ ->
        "n/a"
    end
  end

  # CPU% + mem MB scenarios store the raw measurement in median; print
  # the value directly.
  defp format_median(suite, suffix) do
    case find_scenario_median(suite, suffix) do
      median when is_number(median) -> :erlang.float_to_binary(median * 1.0, decimals: 1)
      _ -> "n/a"
    end
  end

  defp find_scenario_median(suite, suffix) do
    suite
    |> Map.get(:scenarios, [])
    |> Enum.find_value(fn s ->
      if String.ends_with?(s.name, suffix), do: s.run_time_data.statistics.median
    end)
  end

  defp write_meta(dir, %{ctx: ctx} = block) do
    Awfy.Measure.Meta.write(dir, ctx, %{
      "xmpp" => %{
        "scenario" => block.scenario,
        "topology" => to_string(block.topology),
        "users" => block.config.users,
        "domains" => block.config.domains,
        "interarrival_ms" => block.config.interarrival_ms,
        "measurement_duration_s" => block.config.measurement_duration_s,
        "throughput" => block.throughput,
        "cpu_pct" => block.cpu_pct,
        "mem_mb" => block.mem_mb
      },
      # Declares this run's application-benchmark families to the
      # dashboard's geomean aggregator. Cells whose benchmark name
      # starts with `<name>_` collapse into one family contribution,
      # and the suite-wide geomean weights "applications" and
      # "synthetic" categories 50/50 regardless of how many cells
      # each category produced. Future per-app benchmarks (network,
      # ...) extend this list.
      #
      # Family name `xmpp` is suite-neutral — the underlying Amoc
      # scenario stays in block.scenario / meta.xmpp.scenario so a
      # second scenario can join later without renaming the family.
      # Metric short names (cpu / mem / speed) match the cell names
      # in lib/awfy/xmpp/runner.ex.
      "applications" => [
        %{
          "name" => "xmpp",
          "metrics" => ["cpu", "mem", "speed"]
        }
      ]
    })
  end
end
