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
    checks =
      case detect_os() do
        :macos ->
          [
            check_macos_power(),
            check_macos_low_power_mode(),
            check_macos_spotlight(),
            check_macos_time_machine(),
            check_macos_memory_pressure()
          ]

        :linux ->
          [
            check_linux_governor(),
            check_linux_swap(),
            check_linux_free_memory()
          ]

        :windows ->
          [
            check_windows_power_plan(),
            check_windows_pagefile(),
            check_windows_free_memory()
          ]

        _ ->
          []
      end

    Enum.filter(checks, fn
      {:warn, _, _, _} -> true
      _ -> false
    end)
  end

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
  defp run_checks({:other, _}), do: common_only_checks()

  # ===================================================================
  # Output
  # ===================================================================
  defp print_header(:macos) do
    cpu = sysctl_string("machdep.cpu.brand_string") || "?"
    cores = sysctl_int("hw.ncpu") || "?"
    mem_gb = (sysctl_int("hw.memsize") || 0) |> div(1024 * 1024 * 1024)
    os_ver = trim_cmd("sw_vers", ["-productVersion"]) || "?"

    IO.puts("=== AWFY benchmark preflight ===")
    IO.puts("OS:     macOS #{os_ver} (Darwin #{:os.version() |> tuple_to_dotted()})")
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
    checks
    |> Enum.reject(fn {status, _, _, _} -> quiet? and status != :warn end)
    |> Enum.each(fn {status, label, message, fix} ->
      tag = format_tag(status)
      IO.puts("#{tag} #{label}")
      if message && message != "", do: IO.puts("       #{message}")
      if fix, do: IO.puts("       fix: #{fix}")
    end)

    IO.puts("")
  end

  defp print_summary(checks) do
    counts = Enum.frequencies_by(checks, &elem(&1, 0))
    ok = Map.get(counts, :ok, 0)
    warn = Map.get(counts, :warn, 0)
    info = Map.get(counts, :info, 0)
    skip = Map.get(counts, :skip, 0)

    IO.puts(
      "Summary: #{warn} warn, #{ok} ok, #{info} info" <>
        if(skip > 0, do: ", #{skip} skipped", else: "")
    )

    if warn == 0 do
      IO.puts("Looks good — no obvious noise sources detected.")
    else
      IO.puts("Address the WARN items before recording publication-quality numbers.")
    end
  end

  defp format_tag(:ok), do: "[OK]  "
  defp format_tag(:warn), do: "[WARN]"
  defp format_tag(:info), do: "[INFO]"
  defp format_tag(:skip), do: "[SKIP]"

  # ===================================================================
  # macOS checks
  # ===================================================================
  defp macos_checks do
    [
      check_macos_power(),
      check_macos_low_power_mode(),
      check_macos_spotlight(),
      check_macos_time_machine(),
      check_macos_load_avg(),
      check_macos_memory_pressure(),
      check_top_cpu_processes_macos()
    ]
  end

  defp check_macos_power do
    case run_cmd("pmset", ["-g", "batt"]) do
      {:ok, out} ->
        cond do
          String.contains?(out, "AC Power") ->
            {:ok, "AC power", "drawing from AC adapter", nil}

          String.contains?(out, "Battery Power") ->
            {:warn, "On battery power",
             "battery-powered macOS throttles aggressively under thermal/charge constraints",
             "plug in the AC adapter"}

          true ->
            {:info, "Power source", String.trim(out), nil}
        end

      _ ->
        {:skip, "Power source", "pmset unavailable", nil}
    end
  end

  defp check_macos_low_power_mode do
    case run_cmd("pmset", ["-g"]) do
      {:ok, out} ->
        case Regex.run(~r/lowpowermode\s+(\d)/, out) do
          [_, "1"] ->
            {:warn, "Low Power Mode enabled",
             "the OS deliberately reduces CPU clock to save battery",
             "System Settings → Battery → Low Power Mode → Off"}

          [_, "0"] ->
            {:ok, "Low Power Mode", "disabled", nil}

          _ ->
            {:skip, "Low Power Mode", "could not parse pmset output", nil}
        end

      _ ->
        {:skip, "Low Power Mode", "pmset unavailable", nil}
    end
  end

  defp check_macos_spotlight do
    case run_cmd("mdutil", ["-s", "/"]) do
      {:ok, out} ->
        cond do
          String.contains?(out, "Indexing in progress") ->
            {:warn, "Spotlight indexing in progress",
             "mdworker can saturate CPU and disk I/O for minutes at a time",
             "wait for indexing to finish, or temporarily: sudo mdutil -i off /"}

          String.contains?(out, "Indexing enabled") ->
            {:ok, "Spotlight", "indexed but idle", nil}

          String.contains?(out, "Indexing disabled") ->
            {:info, "Spotlight", "indexing disabled (no concern)", nil}

          true ->
            {:info, "Spotlight", String.trim(out), nil}
        end

      _ ->
        {:skip, "Spotlight", "mdutil unavailable", nil}
    end
  end

  defp check_macos_time_machine do
    case run_cmd("tmutil", ["status"]) do
      {:ok, out} ->
        cond do
          String.contains?(out, "Running = 1") ->
            {:warn, "Time Machine backup in progress",
             "backupd reads the whole disk and can spike CPU/IO unpredictably",
             "tmutil stopbackup (will resume next scheduled run)"}

          String.contains?(out, "Running = 0") ->
            {:ok, "Time Machine", "no backup in progress", nil}

          true ->
            {:info, "Time Machine", "status unclear", nil}
        end

      _ ->
        {:skip, "Time Machine", "tmutil unavailable", nil}
    end
  end

  defp check_macos_load_avg do
    case run_cmd("uptime", []) do
      {:ok, out} ->
        case Regex.run(~r/load averages?:\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/, out) do
          [_, l1, _l5, _l15] ->
            cores = sysctl_int("hw.ncpu") || 1
            l1f = parse_float(l1)
            ratio = l1f / cores

            cond do
              ratio < 0.3 ->
                {:ok, "Load average", "1m=#{l1} (#{Float.round(ratio, 2)}× cores)", nil}

              ratio < 0.7 ->
                {:info, "Load average", "1m=#{l1} (#{Float.round(ratio, 2)}× cores) — moderate", nil}

              true ->
                {:warn, "Load average high",
                 "1m=#{l1} on #{cores} cores (#{Float.round(ratio, 2)}× saturation)",
                 "wait for current workload to finish or close CPU-heavy apps"}
            end

          _ ->
            {:skip, "Load average", "could not parse uptime", nil}
        end

      _ ->
        {:skip, "Load average", "uptime unavailable", nil}
    end
  end

  defp check_macos_memory_pressure do
    case run_cmd("memory_pressure", []) do
      {:ok, out} ->
        cond do
          String.contains?(out, "System-wide memory free percentage: ") ->
            case Regex.run(~r/System-wide memory free percentage:\s+(\d+)/, out) do
              [_, pct_s] ->
                pct = String.to_integer(pct_s)

                cond do
                  pct > 25 ->
                    {:ok, "Memory pressure", "#{pct}% free", nil}

                  pct > 10 ->
                    {:info, "Memory pressure", "#{pct}% free — modest", nil}

                  true ->
                    {:warn, "Memory pressure high",
                     "only #{pct}% system-wide free; risk of swap/compression during run",
                     "close memory-heavy apps (browser tabs, IDEs)"}
                end

              _ ->
                {:skip, "Memory pressure", "could not parse memory_pressure output", nil}
            end

          true ->
            {:info, "Memory pressure", String.trim(out) |> String.split("\n") |> hd(), nil}
        end

      _ ->
        {:skip, "Memory pressure", "memory_pressure unavailable", nil}
    end
  end

  defp check_top_cpu_processes_macos do
    case run_cmd("ps", ["-axro", "pid,pcpu,comm"]) do
      {:ok, out} ->
        self_pid = current_os_pid()

        top =
          out
          |> String.split("\n", trim: true)
          # drop header
          |> Enum.drop(1)
          |> Enum.map(&parse_top_line_with_pid/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(fn {pid, _, _} -> pid == self_pid end)
          |> Enum.map(fn {_, pct, name} -> {pct, name} end)
          |> Enum.take(8)

        report_top(top)

      _ ->
        {:skip, "Top CPU processes", "ps unavailable", nil}
    end
  end

  # ===================================================================
  # Linux checks
  # ===================================================================
  defp linux_checks do
    [
      check_linux_governor(),
      check_linux_turbo(),
      check_linux_thp(),
      check_linux_load_avg(),
      check_linux_swap(),
      check_linux_free_memory(),
      check_top_cpu_processes_linux()
    ]
  end

  defp check_linux_governor do
    case Path.wildcard("/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor") do
      [] ->
        {:skip, "CPU governor",
         "no cpufreq sysfs (likely a VM or a hypervisor that hides cpufreq)", nil}

      paths ->
        govs =
          paths
          |> Enum.map(&safe_read/1)
          |> Enum.map(&String.trim/1)
          |> Enum.uniq()

        case govs do
          ["performance"] ->
            {:ok, "CPU governor", "all cores at performance", nil}

          [single] ->
            {:warn, "CPU governor not 'performance'",
             "all cores at #{single}; CPU clock will scale down between bursts",
             "sudo cpupower frequency-set -g performance"}

          mixed ->
            {:warn, "CPU governors mixed",
             "cores running different governors: #{Enum.join(mixed, ", ")}",
             "sudo cpupower frequency-set -g performance"}
        end
    end
  end

  defp check_linux_turbo do
    cond do
      File.exists?("/sys/devices/system/cpu/intel_pstate/no_turbo") ->
        case safe_read("/sys/devices/system/cpu/intel_pstate/no_turbo") do
          "0" <> _ -> {:info, "Turbo Boost", "intel_pstate: enabled", nil}
          "1" <> _ -> {:info, "Turbo Boost", "intel_pstate: disabled (intentional? OK for stable numbers)", nil}
          _ -> {:skip, "Turbo Boost", "could not parse no_turbo", nil}
        end

      File.exists?("/sys/devices/system/cpu/cpufreq/boost") ->
        case safe_read("/sys/devices/system/cpu/cpufreq/boost") do
          "1" <> _ -> {:info, "Turbo Boost", "amd: enabled", nil}
          "0" <> _ -> {:info, "Turbo Boost", "amd: disabled (intentional? OK for stable numbers)", nil}
          _ -> {:skip, "Turbo Boost", "could not parse boost", nil}
        end

      true ->
        {:skip, "Turbo Boost", "no recognizable sysfs entry", nil}
    end
  end

  defp check_linux_thp do
    case safe_read("/sys/kernel/mm/transparent_hugepage/enabled") do
      nil ->
        {:skip, "Transparent Huge Pages", "no THP sysfs entry", nil}

      raw ->
        active =
          Regex.run(~r/\[(\w+)\]/, raw)
          |> case do
            [_, val] -> val
            _ -> "unknown"
          end

        {:info, "Transparent Huge Pages", "active mode: #{active}", nil}
    end
  end

  defp check_linux_load_avg do
    case safe_read("/proc/loadavg") do
      nil ->
        {:skip, "Load average", "/proc/loadavg unavailable", nil}

      out ->
        [l1 | _] = String.split(out, " ", trim: true)
        cores = read_cpuinfo_count() || 1
        l1f = parse_float(l1)
        ratio = l1f / cores

        cond do
          ratio < 0.3 ->
            {:ok, "Load average", "1m=#{l1} (#{Float.round(ratio, 2)}× cores)", nil}

          ratio < 0.7 ->
            {:info, "Load average", "1m=#{l1} (#{Float.round(ratio, 2)}× cores) — moderate", nil}

          true ->
            {:warn, "Load average high",
             "1m=#{l1} on #{cores} cores (#{Float.round(ratio, 2)}× saturation)",
             "wait for current workload to finish, or kill -9 the offender"}
        end
    end
  end

  defp check_linux_swap do
    case safe_read("/proc/meminfo") do
      nil ->
        {:skip, "Swap", "/proc/meminfo unavailable", nil}

      out ->
        total = parse_meminfo_kb(out, "SwapTotal")
        free = parse_meminfo_kb(out, "SwapFree")

        cond do
          total == 0 ->
            {:ok, "Swap", "no swap configured", nil}

          total - free < 32 * 1024 ->
            {:ok, "Swap", "swap configured but unused", nil}

          true ->
            used_mb = (total - free) / 1024

            {:warn, "Swap in use",
             "#{Float.round(used_mb, 0)} MB swapped — disk paging will spike timings",
             "free memory or sudo swapoff -a (will require sufficient RAM)"}
        end
    end
  end

  defp check_linux_free_memory do
    case safe_read("/proc/meminfo") do
      nil ->
        {:skip, "Free memory", "/proc/meminfo unavailable", nil}

      out ->
        avail = parse_meminfo_kb(out, "MemAvailable")

        cond do
          avail == 0 ->
            {:skip, "Free memory", "MemAvailable not reported", nil}

          avail < 1 * 1024 * 1024 ->
            {:warn, "Low free memory",
             "only #{Float.round(avail / 1024 / 1024, 2)} GB available",
             "close memory-heavy apps before measuring"}

          true ->
            {:ok, "Free memory", "#{Float.round(avail / 1024 / 1024, 1)} GB available", nil}
        end
    end
  end

  defp check_top_cpu_processes_linux do
    case run_cmd("ps", ["-axo", "pid,pcpu,comm", "--sort=-pcpu"]) do
      {:ok, out} ->
        self_pid = current_os_pid()

        top =
          out
          |> String.split("\n", trim: true)
          |> Enum.drop(1)
          |> Enum.map(&parse_top_line_with_pid/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(fn {pid, _, _} -> pid == self_pid end)
          |> Enum.map(fn {_, pct, name} -> {pct, name} end)
          |> Enum.take(8)

        report_top(top)

      _ ->
        {:skip, "Top CPU processes", "ps unavailable", nil}
    end
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

  defp check_windows_power_plan do
    case run_cmd("powercfg", ["/getactivescheme"]) do
      {:ok, out} ->
        cond do
          String.contains?(out, "High performance") or
              String.contains?(out, "Ultimate Performance") ->
            {:ok, "Power plan", String.trim(out), nil}

          String.contains?(out, "Balanced") ->
            {:warn, "Power plan: Balanced",
             "Windows will scale CPU clock down between bursts",
             "powercfg /setactive SCHEME_MIN  (or run as admin: powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 to enable Ultimate Performance)"}

          String.contains?(out, "Power saver") ->
            {:warn, "Power plan: Power saver",
             "deliberately throttles to save energy",
             "powercfg /setactive SCHEME_MIN"}

          true ->
            {:info, "Power plan", String.trim(out), nil}
        end

      _ ->
        {:skip, "Power plan", "powercfg unavailable", nil}
    end
  end

  defp check_windows_load do
    # On Windows, "load" is rough — use total CPU usage from PowerShell.
    case run_cmd("powershell", [
           "-NoProfile",
           "-Command",
           "(Get-Counter '\\Processor(_Total)\\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue"
         ]) do
      {:ok, out} ->
        case Float.parse(String.trim(out)) do
          {pct, _} ->
            cond do
              pct < 15 ->
                {:ok, "Total CPU usage", "#{Float.round(pct, 1)}%", nil}

              pct < 40 ->
                {:info, "Total CPU usage", "#{Float.round(pct, 1)}% — moderate", nil}

              true ->
                {:warn, "High total CPU usage",
                 "#{Float.round(pct, 1)}% in use system-wide before benchmarking",
                 "close CPU-heavy apps; check Task Manager"}
            end

          _ ->
            {:skip, "Total CPU usage", "could not parse Get-Counter output", nil}
        end

      _ ->
        {:skip, "Total CPU usage", "powershell Get-Counter unavailable", nil}
    end
  end

  defp check_windows_pagefile do
    case run_cmd("powershell", [
           "-NoProfile",
           "-Command",
           "(Get-CimInstance Win32_PageFileUsage | Measure-Object -Property CurrentUsage -Sum).Sum"
         ]) do
      {:ok, out} ->
        case Integer.parse(String.trim(out)) do
          {mb, _} when mb < 32 ->
            {:ok, "Page file", "no significant usage", nil}

          {mb, _} when mb < 256 ->
            {:info, "Page file", "#{mb} MB in use — modest", nil}

          {mb, _} ->
            {:warn, "Page file in active use",
             "#{mb} MB paged out — disk paging will spike timings",
             "close memory-heavy apps before measuring"}

          _ ->
            {:skip, "Page file", "could not parse Win32_PageFileUsage", nil}
        end

      _ ->
        {:skip, "Page file", "powershell unavailable", nil}
    end
  end

  defp check_windows_free_memory do
    case run_cmd("powershell", [
           "-NoProfile",
           "-Command",
           "(Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory).FreePhysicalMemory"
         ]) do
      {:ok, out} ->
        case Integer.parse(String.trim(out)) do
          {kb, _} ->
            gb = kb / 1024 / 1024

            cond do
              gb >= 4 ->
                {:ok, "Free memory", "#{Float.round(gb, 1)} GB available", nil}

              gb >= 2 ->
                {:info, "Free memory", "#{Float.round(gb, 1)} GB available — modest", nil}

              true ->
                {:warn, "Low free memory",
                 "only #{Float.round(gb, 2)} GB available",
                 "close memory-heavy apps before measuring"}
            end

          _ ->
            {:skip, "Free memory", "could not parse FreePhysicalMemory", nil}
        end

      _ ->
        {:skip, "Free memory", "powershell unavailable", nil}
    end
  end

  defp check_windows_top_cpu_processes do
    case run_cmd("powershell", [
           "-NoProfile",
           "-Command",
           "Get-Process | Where-Object {$_.CPU -gt 0} | Sort-Object -Property CPU -Descending | Select-Object -First 8 Name,CPU | Format-Table -HideTableHeaders"
         ]) do
      {:ok, out} ->
        top =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(String.trim(line), ~r/\s+/, parts: 2) do
              [name, pct] ->
                case Float.parse(pct) do
                  {p, _} -> {p, name}
                  _ -> nil
                end

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        report_top(top)

      _ ->
        {:skip, "Top CPU processes", "powershell unavailable", nil}
    end
  end

  # ===================================================================
  # Common helpers
  # ===================================================================
  defp common_only_checks do
    [{:info, "Limited check coverage", "no platform-specific checks for this OS", nil}]
  end

  defp report_top([]) do
    {:ok, "Top CPU processes", "nothing notable", nil}
  end

  defp report_top(top) do
    total = Enum.reduce(top, 0.0, fn {pct, _}, acc -> acc + pct end)

    biggest =
      top
      |> Enum.map(fn {pct, name} ->
        short = name |> String.split("/") |> List.last() |> String.split() |> hd()
        "#{Float.round(pct, 1)}% #{short}"
      end)
      |> Enum.take(5)
      |> Enum.join(", ")

    cond do
      total < 5.0 ->
        {:ok, "Top CPU processes", "background usage trivial (sum #{Float.round(total, 1)}%)", nil}

      total < 25.0 ->
        {:info, "Top CPU processes", "moderate (top: #{biggest})", nil}

      true ->
        {:warn, "High background CPU usage",
         "top procs: #{biggest}", "close CPU-heavy apps before measuring"}
    end
  end

  defp parse_top_line_with_pid(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 3) do
      [pid_s, pcpu, comm] ->
        with {pid, _} <- Integer.parse(pid_s),
             {pct, _} when pct > 0.0 <- Float.parse(pcpu) do
          {pid, pct, comm}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp current_os_pid do
    case Integer.parse(to_string(:os.getpid())) do
      {n, _} -> n
      _ -> -1
    end
  end

  defp run_cmd(cmd, args) do
    try do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp trim_cmd(cmd, args) do
    case run_cmd(cmd, args) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  defp sysctl_string(key) do
    case run_cmd("sysctl", ["-n", key]) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  defp sysctl_int(key) do
    case sysctl_string(key) do
      nil ->
        nil

      s ->
        case Integer.parse(s) do
          {n, _} -> n
          _ -> nil
        end
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, bin} -> bin
      _ -> nil
    end
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      _ -> 0.0
    end
  end

  defp tuple_to_dotted({a, b, c}), do: "#{a}.#{b}.#{c}"
  defp tuple_to_dotted(other), do: inspect(other)

  defp read_cpuinfo_field(field) do
    case safe_read("/proc/cpuinfo") do
      nil ->
        nil

      out ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, ":", parts: 2) do
            [k, v] ->
              if String.starts_with?(String.trim(k), field), do: String.trim(v), else: nil

            _ ->
              nil
          end
        end)
    end
  end

  defp read_cpuinfo_count do
    case safe_read("/proc/cpuinfo") do
      nil ->
        nil

      out ->
        out
        |> String.split("\n")
        |> Enum.count(fn line -> String.starts_with?(line, "processor") end)
    end
  end

  defp read_meminfo_total_gb do
    case safe_read("/proc/meminfo") do
      nil -> nil
      out -> Float.round(parse_meminfo_kb(out, "MemTotal") / 1024 / 1024, 1)
    end
  end

  defp parse_meminfo_kb(content, key) do
    case Regex.run(~r/#{key}:\s+(\d+)\s+kB/, content) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end
end
