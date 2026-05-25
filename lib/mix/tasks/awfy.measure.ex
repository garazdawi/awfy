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
    out: :string,
    dry_run: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    # In dry-run mode, skip Mix.Task.run("compile", []) — its
    # `==> <dep>` / `Generated <dep> app` banners on stdout would
    # mix into the benchmark-name-per-line output the caller (the
    # canonical step in bench.yml) parses, causing the resolver to
    # treat those banner lines as missing benchmarks. The caller
    # is responsible for running `mix compile` as a separate step
    # before invoking us with --dry-run.
    unless opts[:dry_run] do
      Mix.Task.run("compile", [])
    end

    lang = Helpers.parse_lang(opts[:lang])
    bench_filter = Helpers.parse_benchmarks(opts[:benchmarks])

    candidates =
      Awfy.benchmarks()
      |> Helpers.filter_lang(lang)
      |> Helpers.filter_benchmarks(bench_filter)

    otp_families = otp_families_to_run(bench_filter, opts)

    # Dry-run mode: print the .benchee filenames this task WOULD
    # produce (one per line on stdout), then exit. Used by the
    # resolver (`Awfy.Fill.Resolve`) to compute the canonical
    # benchmark set on each gh-pages probe — single source of
    # truth (the actual measure-task's filter logic) instead of a
    # separately-maintained hardcoded list that drifts when
    # benchmarks are added.
    if opts[:dry_run] do
      names =
        Enum.map(candidates, fn entry -> Awfy.name(entry) end) ++
          Enum.map(otp_families, fn mod -> mod.name() end)

      names
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&IO.puts/1)

      System.halt(0)
    end

    unless opts[:ignore_preflight] do
      enforce_preflight()
    end

    {:ok, run_ctx, dir} = Awfy.Measure.Setup.prepare(opts, :synthetic)
    label = run_ctx.label

    if candidates == [] and otp_families == [] do
      # When `--benchmarks` is set and nothing matches, treat the run
      # as a successful no-op. The bench.yml fill path passes the same
      # `--benchmarks <list>` to every platform's measure job, so a
      # filter like `dynamic_domains_pm_*` (only exists on the XMPP
      # leg) lands on the Windows / synthetic-Linux jobs too — those
      # have zero matches and would otherwise fail the workflow even
      # though the user's intent was platform-scoped from the start.
      # No filter set + empty selection still raises (real
      # misconfiguration: nothing at all to run).
      if bench_filter != nil do
        Mix.shell().info(
          "no scenarios match --benchmarks #{inspect(opts[:benchmarks])} — exiting successfully"
        )

        System.halt(0)
      else
        Mix.raise("no benchmarks selected")
      end
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
      run_ctx: run_ctx,
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

  defp write_meta(dir, %{run_ctx: rc} = ctx) do
    runtime_extras = %{
      "logical_processors" => Helpers.safe_integer(:erlang.system_info(:logical_processors)),
      "wordsize" => :erlang.system_info(:wordsize),
      "smp_support" => :erlang.system_info(:smp_support),
      "nif_version" => to_string(:erlang.system_info(:nif_version)),
      "driver_version" => to_string(:erlang.system_info(:driver_version)),
      "c_compiler_used" => c_compiler_used_string(),
      "mix_env" => to_string(Mix.env())
    }

    config = %{
      "time" => ctx.time,
      "warmup" => ctx.warmup,
      "lang" => to_string(ctx.lang),
      "build_flags" => build_flags_from_prefix()
    }

    Awfy.Measure.Meta.write(
      dir,
      rc,
      %{
        "benchmarks" => benchmark_records(ctx),
        "otp_benchmarks" => otp_benchmark_records(ctx)
      },
      runtime_extras: runtime_extras,
      config: config
    )
  end

  # Compiler identity: prefer `$PREFIX/awfy_compiler.txt` (written at
  # install time from `$CC --version`) over `c_compiler_used`. The
  # runtime query reads __GNUC__/__GNUC_MINOR__/__GNUC_PATCHLEVEL__
  # which clang-on-macOS lies about (returns `{gnuc, {4,2,1}}`), and
  # any other clang-pretending-to-be-gcc has the same problem. The
  # build-time `--version` line is the honest answer. Fall back to
  # the runtime query when the file is missing (Windows installers,
  # legacy bundles, pre-this-feature installs).
  defp c_compiler_used_string do
    case compiler_string_from_prefix() do
      nil -> system_info_compiler_string()
      s -> s
    end
  end

  defp compiler_string_from_prefix do
    case :code.root_dir() do
      :error ->
        nil

      root ->
        path = Path.join(to_string(root), "awfy_compiler.txt")

        case File.read(path) do
          {:ok, content} -> content |> String.trim() |> nil_if_empty()
          _ -> nil
        end
    end
  end

  defp system_info_compiler_string do
    case :erlang.system_info(:c_compiler_used) do
      {cc, ver} when is_atom(cc) ->
        "#{cc} #{compiler_version_string(ver)}"

      other ->
        inspect(other)
    end
  end

  defp compiler_version_string({maj, min}) when is_integer(maj) and is_integer(min),
    do: "#{maj}.#{min}"

  defp compiler_version_string({maj, min, patch})
       when is_integer(maj) and is_integer(min) and is_integer(patch),
       do: "#{maj}.#{min}.#{patch}"

  defp compiler_version_string(v) when is_integer(v), do: Integer.to_string(v)
  defp compiler_version_string(v) when is_binary(v), do: v
  defp compiler_version_string(v), do: inspect(v)

  # bin/install-otp-source-mac.sh writes its full `./configure …` line
  # (or just the flag list — see the install script) to
  # `$PREFIX/awfy_build_config.txt` immediately after build. Read it
  # back here so meta.json captures what the currently-running runtime
  # was actually built with. Returns `nil` when missing (CI / legacy
  # bundle / pre-this-feature install) so the dashboard renders "—".
  defp build_flags_from_prefix do
    case :code.root_dir() do
      :error ->
        nil

      root ->
        path = Path.join(to_string(root), "awfy_build_config.txt")

        case File.read(path) do
          {:ok, content} -> content |> String.trim() |> nil_if_empty()
          _ -> nil
        end
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  # The legacy bundle path (AWFY_TARGET_BUNDLE set, used for OTP < 24)
  # compiles benchmarks under a different Elixir than the host
  # orchestrator — see bin/build-target-bundle.sh + priv/elixir-for-otp.sh.
  # The host's `System.version/0` reports the orchestrator (always
  # recent), which is the wrong number to record for a legacy run.
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

end
