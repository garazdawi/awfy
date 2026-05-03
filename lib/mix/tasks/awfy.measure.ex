# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.Measure do
  @shortdoc "Measure benchmarks under the current OTP+Elixir, save to results/"
  @moduledoc """
  Run the AWFY suite under the currently active OTP+Elixir, save each
  benchmark's Benchee suite to `results/<run-dir>/<bench>.benchee`, and
  write a `meta.json` recording the version, machine, runtime info, and
  per-benchmark source hashes for the run.

  Two-pass design: a verify pass first (one `inner_benchmark_loop(iter)`
  call per scenario), then a timing pass that skips any scenario that
  failed verification. Working scenarios always get saved.

  ## Usage

      mix awfy.measure                        # auto-label from git SHA
      mix awfy.measure --label before-jit2    # custom label
      mix awfy.measure --benchmarks Bounce,Json
      mix awfy.measure --lang erlang
      mix awfy.measure --time 5 --warmup 2
      mix awfy.measure --no-clobber           # refuse to overwrite
      mix awfy.measure --ignore-preflight     # skip preflight gate

  Before timing starts, runs the blocking subset of
  `mix awfy.preflight` and aborts with the suggested fix commands if
  any are flagged. Two categories block:

    * power-state settings whose mid-run change skews timings
      (Low Power Mode, on-battery, CPU governor, Windows power plan)
    * background activity that produces *intermittent* corruption
      (Spotlight, Time Machine, active swap/pagefile, memory pressure)

  Pass `--ignore-preflight` to override for a quick local spot-check.

  See `BENCH_VERSIONS_PLAN.md` for the design.
  """

  use Mix.Task

  alias Awfy.Measure.Helpers

  @switches [
    label: :string,
    benchmarks: :string,
    lang: :string,
    time: :integer,
    warmup: :integer,
    no_clobber: :boolean,
    ignore_preflight: :boolean,
    out: :string
  ]

  @format_version 1

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    unless opts[:ignore_preflight] do
      enforce_preflight()
    end

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

    if File.exists?(dir) do
      if opts[:no_clobber] do
        Mix.raise("results dir #{dir} exists and --no-clobber set")
      else
        Mix.shell().info("[warn] overwriting existing run dir: #{dir}")
        File.rm_rf!(dir)
      end
    end

    File.mkdir_p!(dir)

    lang = Helpers.parse_lang(opts[:lang])
    bench_filter = Helpers.parse_benchmarks(opts[:benchmarks])

    candidates =
      Awfy.benchmarks()
      |> Helpers.filter_lang(lang)
      |> Helpers.filter_benchmarks(bench_filter)

    if candidates == [] do
      Mix.raise("no benchmarks selected")
    end

    Mix.shell().info("=== verify pass (#{length(candidates)} scenarios) ===")
    {ok_entries, broken_entries} = verify_pass(candidates)

    if broken_entries != [] do
      Mix.shell().info(
        "[warn] #{length(broken_entries)} scenario(s) failed verification — skipping in timing pass"
      )

      Enum.each(broken_entries, fn {{lang, mod}, reason} ->
        Mix.shell().info("        #{lang} / #{Awfy.name({lang, mod})}: #{reason}")
      end)
    end

    if ok_entries == [] do
      Mix.raise("no scenarios verified — aborting")
    end

    bench_names_to_run =
      ok_entries
      |> Enum.map(fn entry -> Awfy.name(entry) end)
      |> Enum.uniq()

    user_time = opts[:time]
    user_warmup = opts[:warmup]

    Mix.shell().info(
      "=== timing pass (#{length(ok_entries)} scenarios, " <>
        "time=#{user_time || "per-benchmark"}s warmup=#{user_warmup || 1}s) ==="
    )

    benchee_opts =
      [memory_time: 0, print: [fast_warning: false]]
      |> Helpers.maybe_put(:time, user_time)
      |> Helpers.maybe_put(:warmup, user_warmup)

    Awfy.BencheeRunner.run_all(
      lang: lang,
      benchmarks: bench_names_to_run,
      skip: Enum.map(broken_entries, fn {entry, _} -> entry end),
      save_dir: dir,
      save_tag: label,
      benchee: benchee_opts
    )

    write_meta(dir, %{
      label: label,
      git_sha: git_sha,
      git_dirty: git_dirty?,
      time: user_time,
      warmup: user_warmup || 1,
      lang: lang,
      ok_entries: ok_entries,
      broken_entries: broken_entries,
      bench_names_to_run: bench_names_to_run
    })

    Mix.shell().info("\nWrote #{dir}/")
  end

  defp enforce_preflight do
    case Mix.Tasks.Awfy.Preflight.blocking_warnings() do
      [] ->
        :ok

      warns ->
        Mix.shell().error("Preflight: machine state will distort timings during this run:")

        Enum.each(warns, fn {_, label, msg, fix} ->
          Mix.shell().error("  - #{label}: #{msg}")
          if fix, do: Mix.shell().error("    fix: #{fix}")
        end)

        Mix.shell().error("")

        Mix.shell().error(
          "Run `mix awfy.preflight` for the full report, fix the items above, " <>
            "or pass --ignore-preflight to override."
        )

        Mix.raise("aborted by preflight")
    end
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

  defp verify_pass(candidates) do
    Enum.reduce(candidates, {[], []}, fn entry, {ok, broken} ->
      iter = Awfy.BencheeRunner.inner_iter_for(Awfy.name(entry))

      try do
        case Awfy.verify(entry, iter) do
          true -> {[entry | ok], broken}
          false -> {ok, [{entry, "verify_result returned false"} | broken]}
        end
      rescue
        e -> {ok, [{entry, "raised: #{Exception.message(e)}"} | broken]}
      catch
        kind, reason ->
          {ok, [{entry, "#{kind}: #{inspect(reason)}"} | broken]}
      end
    end)
    |> then(fn {ok, broken} -> {Enum.reverse(ok), Enum.reverse(broken)} end)
  end

  defp write_meta(dir, ctx) do
    {:ok, hostname_charlist} = :inet.gethostname()

    meta = %{
      "format_version" => @format_version,
      "label" => ctx.label,
      "otp" => to_string(System.otp_release()),
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
      "runtime" => %{
        "emu_flavor" => to_string(:erlang.system_info(:emu_flavor)),
        "schedulers_online" => :erlang.system_info(:schedulers_online),
        "logical_processors" => Helpers.safe_integer(:erlang.system_info(:logical_processors)),
        "wordsize" => :erlang.system_info(:wordsize),
        "smp_support" => :erlang.system_info(:smp_support),
        "nif_version" => to_string(:erlang.system_info(:nif_version)),
        "driver_version" => to_string(:erlang.system_info(:driver_version)),
        "mix_env" => to_string(Mix.env())
      },
      "config" => %{
        "time" => ctx.time,
        "warmup" => ctx.warmup,
        "lang" => to_string(ctx.lang)
      },
      "benchmarks" => benchmark_records(ctx)
    }

    File.write!(Path.join(dir, "meta.json"), Jason.encode_to_iodata!(meta))
  end

  defp benchmark_records(ctx) do
    ok_set = MapSet.new(ctx.ok_entries)
    broken = Enum.map(ctx.broken_entries, fn {entry, _} -> entry end)

    (ctx.ok_entries ++ broken)
    |> Enum.group_by(&Awfy.name/1)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, entries} ->
      %{
        "name" => name,
        "inner_iter" => Awfy.BencheeRunner.inner_iter_for(name),
        "languages" =>
          Map.new(entries, fn {lang, mod} = entry ->
            {to_string(lang),
             %{
               "module" => to_string(mod),
               "verified" => MapSet.member?(ok_set, entry),
               "source_sha256" => source_sha256(entry)
             }}
          end)
      }
    end)
  end

  defp source_sha256({:erlang, mod}), do: sha_file(Path.join("src", "#{mod}.erl"))

  defp source_sha256({:elixir, mod}) do
    case mod.module_info(:compile)[:source] do
      nil -> ""
      raw -> raw |> List.to_string() |> Path.relative_to_cwd() |> sha_file()
    end
  end

  defp sha_file(path) do
    case File.read(path) do
      {:ok, bin} ->
        # Strip CR before hashing so a CRLF Windows checkout matches an
        # LF Linux/macOS checkout. .gitattributes pins LF for source
        # files we ship, but defending against the hash drift directly
        # keeps the dashboard's "source changed" warning quiet even if
        # someone clones with a different core.autocrlf setting.
        canonical = :binary.replace(bin, "\r", "", [:global])
        :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)

      _ ->
        ""
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
             field when is_binary(field) <- Awfy.Preflight.Parse.cpuinfo_field(bin, "model name") do
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
