# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.Preflight do
  @shortdoc "Check the machine for benchmark-stability issues"
  @moduledoc """
  Inspects the current machine for system-level conditions that hurt
  benchmark timing stability and prints a checklist:

      [OK]   — nothing to do
      [WARN] — recommended fix; runs may be unreliable until applied
      [INFO] — context, no action required

  Cross-platform: macOS, Linux, Windows. Each platform-specific check
  is skipped silently when the underlying tool is unavailable, so the
  task is safe to run anywhere — it will tell you what it could and
  couldn't determine.

  ## Usage

      mix awfy.preflight
      mix awfy.preflight --quiet            # only WARN, suppress OK/INFO

  Run before a measurement session to catch the obvious noise sources
  (Low Power Mode, Spotlight indexing, runaway browser tabs, missing
  CPU governor, swap pressure, etc.).
  """

  use Mix.Task

  alias Awfy.Preflight.Parse

  @switches [quiet: :boolean]

  # ===================================================================
  # Entry
  # ===================================================================
  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    os = detect_os()
    print_header(os)

    checks = run_checks(os)

    print_checks(checks, opts[:quiet] == true)
    print_summary(checks)
  end

  @doc """
  Returns the subset of preflight checks that should refuse to start
  a benchmark run. Two flavours included:

    * power-state settings whose mid-run change would skew timings
      (Low Power Mode, on-battery, CPU governor, Windows power plan)
    * background activity that produces *intermittent* corruption
      mid-run (Spotlight indexing, Time Machine backups, active swap
      / pagefile, severe memory pressure) — these self-resolve so the
      user can just wait, but a silently-corrupted run wastes minutes
      and may go undetected for weeks.

  Not in the set: high background CPU / load average (too prone to
  false-positives on a developer machine), Turbo Boost off
  (intentional in some setups), THP mode (informational).
  """
  @spec blocking_warnings() ::
          [{:warn, String.t(), String.t(), String.t() | nil}]
  def blocking_warnings do
    blocking_checks(detect_os())
    |> Enum.filter(&match?({:warn, _, _, _}, &1))
  end

  defp blocking_checks(:macos) do
    [
      check_macos_power(),
      check_macos_low_power_mode(),
      check_macos_spotlight(),
      check_macos_time_machine(),
      check_macos_memory_pressure()
    ]
  end

  defp blocking_checks(:linux) do
    [check_linux_governor(), check_linux_swap(), check_linux_free_memory()]
  end

  defp blocking_checks(:windows) do
    [check_windows_power_plan(), check_windows_pagefile(), check_windows_free_memory()]
  end

  defp blocking_checks(_), do: []

  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      {:win32, _} -> :windows
      {family, name} -> {:other, "#{family}/#{name}"}
    end
  end

  defp run_checks(:macos), do: macos_checks()
  defp run_checks(:linux), do: linux_checks()
  defp run_checks(:windows), do: windows_checks()

  defp run_checks({:other, _}),
    do: [{:info, "Limited check coverage", "no platform-specific checks for this OS", nil}]

  # ===================================================================
  # Output
  # ===================================================================
  defp print_header(:macos) do
    cpu = sysctl_string("machdep.cpu.brand_string") || "?"
    cores = sysctl_int("hw.ncpu") || "?"
    mem_gb = (sysctl_int("hw.memsize") || 0) |> div(1024 * 1024 * 1024)
    os_ver = trim_cmd("sw_vers", ["-productVersion"]) || "?"

    IO.puts("=== AWFY benchmark preflight ===")
    IO.puts("OS:     macOS #{os_ver} (Darwin #{:os.version() |> Parse.tuple_to_dotted()})")
    IO.puts("CPU:    #{cpu} (#{cores} cores)")
    IO.puts("Memory: #{mem_gb} GB")
    IO.puts("")
  end

  defp print_header(:linux) do
    cpu = read_cpuinfo_field("model name") || "?"
    cores = read_cpuinfo_count() || "?"
    mem_gb = read_meminfo_total_gb() || "?"
    kernel = trim_cmd("uname", ["-sr"]) || "?"

    IO.puts("=== AWFY benchmark preflight ===")
    IO.puts("OS:     #{kernel}")
    IO.puts("CPU:    #{cpu} (#{cores} cores)")
    IO.puts("Memory: #{mem_gb} GB")
    IO.puts("")
  end

  defp print_header(:windows) do
    IO.puts("=== AWFY benchmark preflight ===")
    IO.puts("OS:     Windows")
    IO.puts("")
  end

  defp print_header({:other, name}) do
    IO.puts("=== AWFY benchmark preflight ===")
    IO.puts("OS:     #{name} (limited check coverage)")
    IO.puts("")
  end

  defp print_checks(checks, quiet?) do
    Enum.each(checks, fn {status, label, message, fix} ->
      unless quiet? and status != :warn do
        IO.puts("#{tag(status)} #{label}")
        if message not in [nil, ""], do: IO.puts("       #{message}")
        if fix, do: IO.puts("       fix: #{fix}")
      end
    end)

    IO.puts("")
  end

  defp print_summary(checks) do
    c = Enum.frequencies_by(checks, &elem(&1, 0))
    skip = Map.get(c, :skip, 0)

    summary =
      "Summary: #{Map.get(c, :warn, 0)} warn, #{Map.get(c, :ok, 0)} ok, " <>
        "#{Map.get(c, :info, 0)} info" <> if(skip > 0, do: ", #{skip} skipped", else: "")

    IO.puts(summary)

    if Map.get(c, :warn, 0) == 0 do
      IO.puts("Looks good — no obvious noise sources detected.")
    else
      IO.puts("Address the WARN items before recording publication-quality numbers.")
    end
  end

  defp tag(:ok), do: "[OK]  "
  defp tag(:warn), do: "[WARN]"
  defp tag(:info), do: "[INFO]"
  defp tag(:skip), do: "[SKIP]"

  # ===================================================================
  # macOS checks
  # ===================================================================
  defp macos_checks do
    [
      check_macos_power(),
      check_macos_low_power_mode(),
      check_macos_spotlight(),
      check_macos_time_machine(),
      check_load_avg(:macos),
      check_macos_memory_pressure(),
      check_top_cpu_unix("ps", ["-axro", "pid,pcpu,comm"])
    ]
  end

  defp check_macos_power do
    probe("Power source", "pmset", ["-g", "batt"], fn out ->
      case Parse.power_source(out) do
        :ac ->
          {:ok, "AC power", "drawing from AC adapter", nil}

        :battery ->
          {:warn, "On battery power",
           "battery-powered macOS throttles aggressively under thermal/charge constraints",
           "plug in the AC adapter"}

        :unknown ->
          {:info, "Power source", String.trim(out), nil}
      end
    end)
  end

  defp check_macos_low_power_mode do
    probe("Low Power Mode", "pmset", ["-g"], fn out ->
      case Parse.lowpowermode(out) do
        :on ->
          {:warn, "Low Power Mode enabled",
           "the OS deliberately reduces CPU clock to save battery",
           "System Settings → Battery → Low Power Mode → Off"}

        :off ->
          {:ok, "Low Power Mode", "disabled", nil}

        :unknown ->
          {:skip, "Low Power Mode", "could not parse pmset output", nil}
      end
    end)
  end

  defp check_macos_spotlight do
    probe("Spotlight", "mdutil", ["-s", "/"], fn out ->
      case Parse.spotlight_state(out) do
        :indexing ->
          {:warn, "Spotlight indexing in progress",
           "mdworker can saturate CPU and disk I/O for minutes at a time",
           "wait for indexing to finish, or temporarily: sudo mdutil -i off /"}

        :idle ->
          {:ok, "Spotlight", "indexed but idle", nil}

        :disabled ->
          {:info, "Spotlight", "indexing disabled (no concern)", nil}

        :unknown ->
          {:info, "Spotlight", String.trim(out), nil}
      end
    end)
  end

  defp check_macos_time_machine do
    probe("Time Machine", "tmutil", ["status"], fn out ->
      case Parse.time_machine_state(out) do
        :running ->
          {:warn, "Time Machine backup in progress",
           "backupd reads the whole disk and can spike CPU/IO unpredictably",
           "tmutil stopbackup (will resume next scheduled run)"}

        :idle ->
          {:ok, "Time Machine", "no backup in progress", nil}

        :unknown ->
          {:info, "Time Machine", "status unclear", nil}
      end
    end)
  end

  defp check_macos_memory_pressure do
    probe("Memory pressure", "memory_pressure", [], fn out ->
      case Parse.memory_pressure_pct(out) do
        nil -> {:info, "Memory pressure", out |> String.trim() |> String.split("\n") |> hd(), nil}
        pct -> Parse.judge_memory_pressure(pct)
      end
    end)
  end

  # ===================================================================
  # Linux checks
  # ===================================================================
  defp linux_checks do
    [
      check_linux_governor(),
      check_linux_turbo(),
      check_linux_thp(),
      check_load_avg(:linux),
      check_linux_swap(),
      check_linux_free_memory(),
      check_top_cpu_unix("ps", ["-axo", "pid,pcpu,comm", "--sort=-pcpu"])
    ]
  end

  defp check_linux_swap do
    check_linux_meminfo("Swap", fn out ->
      Parse.judge_swap(Parse.meminfo_kb(out, "SwapTotal"), Parse.meminfo_kb(out, "SwapFree"))
    end)
  end

  defp check_linux_free_memory do
    check_linux_meminfo("Free memory", fn out ->
      Parse.judge_linux_free_memory(Parse.meminfo_kb(out, "MemAvailable"))
    end)
  end

  defp check_linux_governor do
    case Path.wildcard("/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor") do
      [] ->
        {:skip, "CPU governor",
         "no cpufreq sysfs (likely a VM or a hypervisor that hides cpufreq)", nil}

      paths ->
        paths |> Enum.map(&safe_read/1) |> Enum.map(&String.trim/1) |> Parse.judge_governor()
    end
  end

  # intel_pstate: no_turbo=0 → on. AMD cpufreq: boost=1 → on. Different semantics
  # for the same sysfs node convention, so we encode both as `{label, path, on}`.
  defp check_linux_turbo do
    candidates = [
      {"intel_pstate", "/sys/devices/system/cpu/intel_pstate/no_turbo", "0"},
      {"amd", "/sys/devices/system/cpu/cpufreq/boost", "1"}
    ]

    case Enum.find(candidates, fn {_, p, _} -> File.exists?(p) end) do
      nil ->
        {:skip, "Turbo Boost", "no recognizable sysfs entry", nil}

      {label, path, on} ->
        case safe_read(path) do
          nil ->
            {:skip, "Turbo Boost", "could not read #{Path.basename(path)}", nil}

          raw ->
            state =
              if String.starts_with?(raw, on),
                do: "enabled",
                else: "disabled (intentional? OK for stable numbers)"

            {:info, "Turbo Boost", "#{label}: #{state}", nil}
        end
    end
  end

  defp check_linux_thp do
    probe_file("Transparent Huge Pages", "/sys/kernel/mm/transparent_hugepage/enabled", fn raw ->
      {:info, "Transparent Huge Pages", "active mode: #{Parse.thp_active(raw)}", nil}
    end)
  end

  defp check_linux_meminfo(label, judge) do
    probe_file(label, "/proc/meminfo", judge)
  end

  # ===================================================================
  # Windows checks
  # ===================================================================
  defp windows_checks do
    [
      check_windows_power_plan(),
      check_windows_load(),
      check_windows_pagefile(),
      check_windows_free_memory(),
      check_windows_top_cpu_processes()
    ]
  end

  defp check_windows_load do
    pwsh_number(
      "Total CPU usage",
      "(Get-Counter '\\Processor(_Total)\\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue",
      &Float.parse/1,
      &Parse.judge_windows_cpu/1
    )
  end

  defp check_windows_pagefile do
    pwsh_number(
      "Page file",
      "(Get-CimInstance Win32_PageFileUsage | Measure-Object -Property CurrentUsage -Sum).Sum",
      &Integer.parse/1,
      &Parse.judge_windows_pagefile/1
    )
  end

  defp check_windows_free_memory do
    pwsh_number(
      "Free memory",
      "(Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory).FreePhysicalMemory",
      &Integer.parse/1,
      &Parse.judge_windows_free_memory/1
    )
  end

  defp check_windows_power_plan do
    probe("Power plan", "powercfg", ["/getactivescheme"], fn out ->
      case Parse.power_plan(out) do
        :high ->
          {:ok, "Power plan", String.trim(out), nil}

        :balanced ->
          {:warn, "Power plan: Balanced", "Windows will scale CPU clock down between bursts",
           "powercfg /setactive SCHEME_MIN  (or run as admin: powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 to enable Ultimate Performance)"}

        :saver ->
          {:warn, "Power plan: Power saver", "deliberately throttles to save energy",
           "powercfg /setactive SCHEME_MIN"}

        :other ->
          {:info, "Power plan", String.trim(out), nil}
      end
    end)
  end

  defp check_windows_top_cpu_processes do
    probe(
      "Top CPU processes",
      "powershell",
      pwsh_args(
        "Get-Process | Where-Object {$_.CPU -gt 0} | Sort-Object -Property CPU -Descending | Select-Object -First 8 Name,CPU | Format-Table -HideTableHeaders"
      ),
      fn out ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&Parse.windows_top_line/1)
        |> Enum.reject(&is_nil/1)
        |> Parse.judge_top()
      end
    )
  end

  # ===================================================================
  # Cross-platform check helpers
  # ===================================================================

  # Read load avg from a platform-specific source and judge it.
  defp check_load_avg(:macos) do
    probe("Load average", "uptime", [], fn out ->
      case Regex.run(~r/load averages?:\s+([\d.]+)/, out) do
        [_, l1] -> Parse.judge_load_avg(Parse.parse_float(l1), sysctl_int("hw.ncpu") || 1)
        _ -> {:skip, "Load average", "could not parse uptime", nil}
      end
    end)
  end

  defp check_load_avg(:linux) do
    probe_file("Load average", "/proc/loadavg", fn out ->
      [l1 | _] = String.split(out, " ", trim: true)
      Parse.judge_load_avg(Parse.parse_float(l1), read_cpuinfo_count() || 1)
    end)
  end

  # Top-CPU-processes on macOS and Linux share everything but the ps args.
  defp check_top_cpu_unix(cmd, args) do
    probe("Top CPU processes", cmd, args, fn out ->
      self_pid = current_os_pid()

      out
      |> String.split("\n", trim: true)
      # drop ps header
      |> Enum.drop(1)
      |> Enum.map(&Parse.top_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(fn {pid, _, _} -> pid == self_pid end)
      |> Enum.map(fn {_, pct, name} -> {pct, name} end)
      |> Enum.take(8)
      |> Parse.judge_top()
    end)
  end

  # ===================================================================
  # Common probes / utilities
  # ===================================================================

  # Run `cmd args`; on success pass the (untrimmed) stdout to `fun`. On any
  # failure (non-zero exit, missing executable, raised error) emit a stable
  # `:skip` line — preflight is supposed to be safe to run anywhere.
  defp probe(label, cmd, args, fun) do
    case run_cmd(cmd, args) do
      {:ok, out} -> fun.(out)
      _ -> {:skip, label, "#{cmd} unavailable", nil}
    end
  end

  defp probe_file(label, path, fun) do
    case safe_read(path) do
      nil -> {:skip, label, "#{path} unavailable", nil}
      out -> fun.(out)
    end
  end

  # Probe a numeric PowerShell expression. `parse` is `Integer.parse/1` or
  # `Float.parse/1`, `judge` takes the parsed number.
  defp pwsh_number(label, expr, parse, judge) do
    probe(label, "powershell", pwsh_args(expr), fn out ->
      case parse.(String.trim(out)) do
        {n, _} -> judge.(n)
        _ -> {:skip, label, "could not parse output", nil}
      end
    end)
  end

  defp pwsh_args(expr), do: ["-NoProfile", "-Command", expr]

  defp current_os_pid do
    case Integer.parse(to_string(:os.getpid())) do
      {n, _} -> n
      _ -> -1
    end
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp trim_cmd(cmd, args) do
    with {:ok, out} <- run_cmd(cmd, args), do: String.trim(out)
  end

  defp sysctl_string(key), do: trim_cmd("sysctl", ["-n", key])

  defp sysctl_int(key) do
    with s when is_binary(s) <- sysctl_string(key),
         {n, _} <- Integer.parse(s) do
      n
    else
      _ -> nil
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, bin} -> bin
      _ -> nil
    end
  end

  defp read_cpuinfo, do: safe_read("/proc/cpuinfo")

  defp read_cpuinfo_field(field) do
    with raw when is_binary(raw) <- read_cpuinfo(), do: Parse.cpuinfo_field(raw, field)
  end

  defp read_cpuinfo_count do
    with raw when is_binary(raw) <- read_cpuinfo(), do: Parse.cpuinfo_count(raw)
  end

  defp read_meminfo_total_gb do
    with raw when is_binary(raw) <- safe_read("/proc/meminfo") do
      Float.round(Parse.meminfo_kb(raw, "MemTotal") / 1024 / 1024, 1)
    end
  end
end
