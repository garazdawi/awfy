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
      mix awfy.measure --benchmarks phash2    # also matches OtpBenchmarks families
      mix awfy.measure --lang erlang
      mix awfy.measure --time 5 --warmup 2
      mix awfy.measure --no-clobber           # refuse to overwrite
      mix awfy.measure --ignore-preflight     # skip preflight gate
      mix awfy.measure --no-otp-benchmarks    # AWFY only, skip the OtpBenchmarks pass

  ## Two suites in one run

  Each invocation runs both the AWFY cross-language suite and the
  OtpBenchmarks BEAM-internal suite (phash2 today, ETS / Mnesia /
  estone over time — see `PLAN/EXTENDED_BENCH_PLAN.md`). Outputs
  land in the same run-dir. Both suites run uniformly across the
  modern peer flow (OTP ≥ 24, same-OTP) and the legacy bundle-target
  flow (OTP < 24); the dispatch lives in each suite's runner and
  is transparent to this task.

  `--benchmarks` filters across both suites by family name
  (`Bounce` matches the AWFY entry, `phash2` matches the
  OtpBenchmarks family). When the filter contains only
  OtpBenchmarks names, the AWFY pass is a no-op rather than an
  error.

  Before timing starts, runs the blocking subset of
  `mix awfy.preflight` and aborts with the suggested fix commands if
  any are flagged. Two categories block:

    * power-state settings whose mid-run change skews timings
      (Low Power Mode, on-battery, CPU governor, Windows power plan)
    * background activity that produces *intermittent* corruption
      (Spotlight, Time Machine, active swap/pagefile, memory pressure)

  Pass `--ignore-preflight` to override for a quick local spot-check.

  See `PLAN/BENCH_VERSIONS_PLAN.md` for the design.
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
    no_otp_benchmarks: :boolean,
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

    otp_families = otp_families_to_run(bench_filter, opts)

    if candidates == [] and otp_families == [] do
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

    if ok_entries == [] and otp_families == [] do
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

    if ok_entries != [] do
      Awfy.BencheeRunner.run_all(
        lang: lang,
        benchmarks: bench_names_to_run,
        skip: Enum.map(broken_entries, fn {entry, _} -> entry end),
        save_dir: dir,
        save_tag: label,
        benchee: benchee_opts
      )
    end

    if otp_families != [] do
      Mix.shell().info(
        "\n=== OtpBenchmarks pass (#{length(otp_families)} famil" <>
          (if length(otp_families) == 1, do: "y", else: "ies") <> ") ==="
      )

      otp_benchee_opts =
        [memory_time: 0, print: [fast_warning: false]]
        |> Helpers.maybe_put(:time, user_time)
        |> Helpers.maybe_put(:warmup, user_warmup)

      Awfy.OtpBenchmarks.Runner.run_all(
        benchmarks: Enum.map(otp_families, & &1.name()),
        save_dir: dir,
        save_tag: label,
        benchee: otp_benchee_opts
      )
    end

    write_meta(dir, %{
      label: label,
      git_sha: git_sha,
      git_dirty: git_dirty?,
      time: user_time,
      warmup: user_warmup || 1,
      lang: lang,
      ok_entries: ok_entries,
      broken_entries: broken_entries,
      bench_names_to_run: bench_names_to_run,
      otp_families: otp_families
    })

    Mix.shell().info("\nWrote #{dir}/")
  end

  # Compute the OtpBenchmarks families to measure in this run. Honors:
  #   * `--no-otp-benchmarks` — explicit opt-out.
  #   * `--benchmarks <list>` — same name-set filter as AWFY uses; an
  #     empty filter (nil) means "every registered family".
  #
  # Bundle-target mode (`AWFY_TARGET_ERL` set) is no longer
  # short-circuited — `Awfy.OtpBenchmarks.Runner.run_one` detects
  # the env var and routes through `Awfy.Runner.run_otp_family/3`,
  # so the same families measure across modern peer-flow and legacy
  # bundle-target legs uniformly.
  defp otp_families_to_run(bench_filter, opts) do
    if opts[:no_otp_benchmarks] do
      []
    else
      OtpBenchmarks.benchmarks()
      |> filter_otp_families(bench_filter)
    end
  end

  defp filter_otp_families(mods, nil), do: mods

  defp filter_otp_families(mods, names) when is_list(names) do
    set = MapSet.new(names)
    Enum.filter(mods, fn mod -> MapSet.member?(set, mod.name()) end)
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
    total = length(candidates)

    candidates
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {entry, idx}, {ok, broken} ->
      name = Awfy.name(entry)
      # Per-scenario progress logged before the call so a hard crash
      # (peer-spawn failure, port termination — anything that bypasses
      # the rescue/catch below) is identifiable from the runner log.
      Mix.shell().info("  [#{idx}/#{total}] verify #{name}")
      iter = Awfy.BencheeRunner.inner_iter_for(name)

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
      "otp" => otp_version_label(),
      "elixir" => System.version(),
      "timestamp" => trend_timestamp() |> DateTime.to_iso8601(),
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
      "benchmarks" => benchmark_records(ctx),
      "otp_benchmarks" => otp_benchmark_records(ctx)
    }

    File.write!(Path.join(dir, "meta.json"), Jason.encode_to_iodata!(meta))
  end

  # Mirror of `benchmark_records/1` for the OtpBenchmarks suite.
  # Per-family entry shape:
  #   * name        — family display name ("phash2"). Matches the
  #                   `<name>.benchee` filename in the run-dir.
  #   * scenarios   — sorted list of input names declared by the
  #                   family (via `inputs/0`). Captured at meta-
  #                   write time so the dashboard can show "this
  #                   run measured these 13 inputs" even if the
  #                   .benchee parse later falls over.
  #   * source_sha256 — hash of the family module's source file,
  #                   same canonicalisation as AWFY (CRLF stripped
  #                   so Windows checkouts match LF on Linux/macOS).
  defp otp_benchmark_records(ctx) do
    Enum.map(ctx.otp_families, fn mod ->
      %{
        "name" => mod.name(),
        "scenarios" => mod.inputs() |> Map.keys() |> Enum.sort(),
        "source_sha256" => source_sha256_for_module(mod)
      }
    end)
  end

  defp source_sha256_for_module(mod) do
    case mod.module_info(:compile)[:source] do
      nil -> ""
      raw -> raw |> List.to_string() |> Path.relative_to_cwd() |> sha_file()
    end
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

  # Both Erlang and Elixir modules expose `module_info(:compile)[:source]`
  # — the absolute path the BEAM was compiled from. We don't hard-code
  # the directory because benchmark suites live under `apps/<group>/src/`
  # or `apps/<group>/lib/`, and that's per-suite.
  defp source_sha256({_lang, mod}) do
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

  # Timestamp used as the trend-axis position for a run. Defaults to
  # measurement wall-clock, but CI overrides it to the OTP commit's
  # committer date via AWFY_OTP_COMMIT_TIMESTAMP — that way old OTP
  # benchmarks measured today plot at the OTP commit's actual point in
  # time rather than clustering at "today" with every other catch-up
  # run. If the env var is malformed we warn and fall back rather than
  # silently writing now (silent fallback hid a months-old config bug
  # in a previous iteration).
  defp trend_timestamp do
    case System.get_env("AWFY_OTP_COMMIT_TIMESTAMP") do
      nil ->
        DateTime.utc_now()

      "" ->
        DateTime.utc_now()

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} ->
            dt

          _ ->
            IO.warn("AWFY_OTP_COMMIT_TIMESTAMP=#{inspect(iso)} is not ISO 8601, using wall-clock")
            DateTime.utc_now()
        end
    end
  end

  # The recorded OTP version drives the trend chart's x axis. Prefer
  # an explicit AWFY_OTP_VERSION (set by CI from the resolved feature
  # release — "20.1", "21.3", "master") so plots can distinguish
  # patch-level runs once we benchmark them. Otherwise read the
  # OTP_VERSION file under the install root, which has the full
  # "X.Y.Z[.P]" string for every modern OTP source build. Last resort:
  # System.otp_release/0, which only carries the major.
  defp otp_version_label do
    case System.get_env("AWFY_OTP_VERSION") do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        otp_version_label_from_file() || to_string(System.otp_release())
    end
  end

  defp otp_version_label_from_file do
    release = to_string(System.otp_release())
    path = Path.join([:code.root_dir() |> to_string(), "releases", release, "OTP_VERSION"])

    case File.read(path) do
      {:ok, contents} -> contents |> String.trim() |> case do
                           "" -> nil
                           v -> v
                         end
      _ -> nil
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
