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

  See `BENCH_VERSIONS_PLAN.md` for the design.
  """

  use Mix.Task

  @switches [
    label: :string,
    benchmarks: :string,
    lang: :string,
    time: :integer,
    warmup: :integer,
    no_clobber: :boolean,
    out: :string
  ]

  @format_version 1

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    {git_sha, git_dirty?} = git_state()
    label = opts[:label] || auto_label(git_sha, git_dirty?)

    out_root = opts[:out] || "results"
    dir = run_dir(out_root, label)

    if File.exists?(dir) do
      if opts[:no_clobber] do
        Mix.raise("results dir #{dir} exists and --no-clobber set")
      else
        Mix.shell().info("[warn] overwriting existing run dir: #{dir}")
        File.rm_rf!(dir)
      end
    end

    File.mkdir_p!(dir)

    lang = parse_lang(opts[:lang])
    bench_filter = parse_benchmarks(opts[:benchmarks])

    candidates =
      Awfy.benchmarks()
      |> filter_lang(lang)
      |> filter_benchmarks(bench_filter)

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
      |> maybe_put(:time, user_time)
      |> maybe_put(:warmup, user_warmup)

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

  defp auto_label(sha, false), do: sha

  defp auto_label(sha, true) do
    ts =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace("Z", "")
      |> binary_part(0, 13)

    "#{sha}-dirty_#{ts}"
  end

  defp git_state do
    sha =
      case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> "unknown"
      end

    dirty? =
      case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out) != ""
        _ -> false
      end

    {sha, dirty?}
  end

  defp run_dir(out_root, label) do
    ts =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace("Z", "")
      |> binary_part(0, 13)

    otp = System.otp_release()
    elixir = System.version()
    Path.join(out_root, "#{ts}_otp#{otp}_elixir#{elixir}_#{label}")
  end

  defp parse_lang(nil), do: :both
  defp parse_lang("both"), do: :both
  defp parse_lang("erlang"), do: :erlang
  defp parse_lang("elixir"), do: :elixir
  defp parse_lang(other), do: Mix.raise("unknown --lang: #{inspect(other)}")

  defp parse_benchmarks(nil), do: nil
  defp parse_benchmarks(s), do: String.split(s, ",", trim: true)

  defp filter_lang(entries, :both), do: entries
  defp filter_lang(entries, lang), do: Enum.filter(entries, fn {l, _} -> l == lang end)

  defp filter_benchmarks(entries, nil), do: entries

  defp filter_benchmarks(entries, names) do
    set = MapSet.new(names)
    Enum.filter(entries, fn entry -> MapSet.member?(set, Awfy.name(entry)) end)
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
        "logical_processors" => safe_integer(:erlang.system_info(:logical_processors)),
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

    json_iodata = :json.encode(meta)
    File.write!(Path.join(dir, "meta.json"), json_iodata)
  end

  defp benchmark_records(ctx) do
    ok_set = MapSet.new(ctx.ok_entries)

    by_name =
      (ctx.ok_entries ++ Enum.map(ctx.broken_entries, fn {entry, _} -> entry end))
      |> Enum.group_by(fn entry -> Awfy.name(entry) end)

    by_name
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name ->
      entries = Map.fetch!(by_name, name)
      iter = Awfy.BencheeRunner.inner_iter_for(name)

      langs =
        Map.new(entries, fn {lang, mod} = entry ->
          verified = MapSet.member?(ok_set, entry)
          sha = source_sha256(entry)

          {to_string(lang),
           %{
             "module" => to_string(mod),
             "verified" => verified,
             "source_sha256" => sha
           }}
        end)

      %{
        "name" => name,
        "inner_iter" => iter,
        "languages" => langs
      }
    end)
  end

  defp source_sha256({:erlang, mod}) do
    path = Path.join("src", "#{mod}.erl")
    sha_file(path)
  end

  defp source_sha256({:elixir, mod}) do
    case mod.module_info(:compile)[:source] do
      nil ->
        ""

      raw ->
        path = List.to_string(raw)
        rel = if Path.type(path) == :absolute, do: Path.relative_to_cwd(path), else: path
        sha_file(rel)
    end
  end

  defp sha_file(path) do
    case File.read(path) do
      {:ok, bin} -> :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
      _ -> ""
    end
  end

  defp os_string do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("uname", ["-sr"]) do
          {out, 0} -> String.trim(out)
          _ -> "Darwin"
        end

      {:unix, :linux} ->
        case System.cmd("uname", ["-sr"]) do
          {out, 0} -> String.trim(out)
          _ -> "Linux"
        end

      {family, name} ->
        "#{family}/#{name}"
    end
  end

  defp cpu_string do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> "unknown"
        end

      {:unix, :linux} ->
        case File.read("/proc/cpuinfo") do
          {:ok, bin} ->
            bin
            |> String.split("\n")
            |> Enum.find_value("unknown", fn l ->
              case String.split(l, ":", parts: 2) do
                ["model name" <> _, val] -> String.trim(val)
                _ -> false
              end
            end)

          _ ->
            "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp safe_integer(:unknown), do: nil
  defp safe_integer(n) when is_integer(n), do: n
  defp safe_integer(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
