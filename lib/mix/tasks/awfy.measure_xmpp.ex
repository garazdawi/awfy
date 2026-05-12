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

  alias Awfy.Measure.Helpers
  alias Awfy.SuiteSlim
  alias Awfy.Xmpp.Runner

  @switches [
    scenario: :string,
    topology: :string,
    label: :string,
    out: :string,
    no_clobber: :boolean
  ]

  @format_version 1
  @default_scenario "dynamic_domains_pm"
  @default_topology "local"

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    scenario = opts[:scenario] || @default_scenario
    topology = parse_topology(opts[:topology] || @default_topology)

    {git_sha, git_dirty?} = git_state()
    label = opts[:label] || Helpers.auto_label(git_sha, git_dirty?, DateTime.utc_now())

    out_root = opts[:out] || "results"

    dir =
      Helpers.run_dir(
        out_root,
        label,
        DateTime.utc_now(),
        System.otp_release(),
        System.version()
      )

    prepare_dir(dir, opts[:no_clobber])

    Mix.shell().info("=== xmpp bench: #{scenario} on #{topology} ===")

    case Runner.run(scenario, topology) do
      {:ok, %{samples: samples, suite: suite, config: config}} ->
        save_path = Path.join(dir, "#{scenario}.benchee")
        write_suite(save_path, suite)

        write_meta(dir, %{
          scenario: scenario,
          topology: topology,
          label: label,
          git_sha: git_sha,
          git_dirty: git_dirty?,
          config: config,
          samples: samples
        })

        Mix.shell().info(
          "\nWrote #{save_path} (#{length(samples)} samples, " <>
            "median #{format_throughput(suite)} msg/s)"
        )

      {:error, reason} ->
        Mix.raise("xmpp bench run failed: #{inspect(reason)}")
    end
  end

  defp parse_topology("local"), do: :local
  defp parse_topology("aws_clt"), do: :aws_clt
  defp parse_topology(other), do: Mix.raise("unknown --topology: #{inspect(other)}")

  defp prepare_dir(dir, no_clobber) do
    if File.exists?(dir) do
      if no_clobber do
        Mix.raise("results dir #{dir} exists and --no-clobber set")
      else
        Mix.shell().info("[warn] overwriting existing run dir: #{dir}")
        File.rm_rf!(dir)
      end
    end

    File.mkdir_p!(dir)
  end

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

  defp format_throughput(suite) do
    case suite do
      %{scenarios: [%{run_time_data: %{statistics: %{median: median}}} | _]}
      when is_number(median) and median > 0 ->
        :erlang.float_to_binary(1_000_000_000 / median, decimals: 1)

      _ ->
        "n/a"
    end
  end

  defp write_meta(dir, ctx) do
    {:ok, hostname_charlist} = :inet.gethostname()

    meta = %{
      "format_version" => @format_version,
      "label" => ctx.label,
      "otp" => otp_version_label(),
      "elixir" => System.version(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "git" => %{
        "sha" => ctx.git_sha,
        "dirty" => ctx.git_dirty
      },
      "machine" => %{
        "hostname" => List.to_string(hostname_charlist),
        "os" => os_string(),
        "cpu" => cpu_string(),
        "arch" => to_string(:erlang.system_info(:system_architecture)),
        "cores" => System.schedulers_online()
      },
      "xmpp" => %{
        "scenario" => ctx.scenario,
        "topology" => to_string(ctx.topology),
        "users" => ctx.config.users,
        "domains" => ctx.config.domains,
        "interarrival_ms" => ctx.config.interarrival_ms,
        "measurement_duration_s" => ctx.config.measurement_duration_s,
        "samples" => ctx.samples
      }
    }

    File.write!(Path.join(dir, "meta.json"), Jason.encode_to_iodata!(meta))
  end

  defp git_state do
    sha = git(["rev-parse", "--short", "HEAD"]) || "unknown"
    dirty? = (git(["status", "--porcelain"]) || "") != ""
    {sha, dirty?}
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp otp_version_label do
    release = to_string(System.otp_release())
    path = Path.join([:code.root_dir() |> to_string(), "releases", release, "OTP_VERSION"])

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> release
          v -> v
        end

      _ ->
        release
    end
  end

  defp os_string do
    case :os.type() do
      {:unix, :darwin} -> trim_cmd("uname", ["-sr"]) || "Darwin"
      {:unix, :linux} -> trim_cmd("uname", ["-sr"]) || "Linux"
      {family, name} -> "#{family}/#{name}"
    end
  end

  defp cpu_string do
    case :os.type() do
      {:unix, :darwin} ->
        trim_cmd("sysctl", ["-n", "machdep.cpu.brand_string"]) || "unknown"

      {:unix, :linux} ->
        with {:ok, bin} <- File.read("/proc/cpuinfo"),
             field when is_binary(field) <-
               Awfy.Preflight.Parse.cpuinfo_field(bin, "model name") do
          field
        else
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp trim_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end
end
