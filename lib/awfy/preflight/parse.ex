# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Preflight.Parse do
  @moduledoc """
  Pure parsers and threshold judgements used by `Mix.Tasks.Awfy.Preflight`.
  Extracted so the regex-and-arithmetic-heavy bits can be tested
  without invoking `pmset`, `mdutil`, `Get-Counter`, etc.

  The judgement functions return the same 4-tuple shape the task
  emits (`{:ok | :warn | :info, label, message, fix}`); the calling
  check_* functions in the task only have to feed parsed inputs in.
  """

  @type status :: :ok | :warn | :info | :skip
  @type check :: {status(), String.t(), String.t() | nil, String.t() | nil}

  # ===================================================================
  # Low-level parsers
  # ===================================================================

  @doc "Parse a `/proc/meminfo` row in kB. Returns 0 when the field is missing."
  @spec meminfo_kb(String.t(), String.t()) :: integer()
  def meminfo_kb(content, key) do
    case Regex.run(~r/#{key}:\s+(\d+)\s+kB/, content) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  @doc """
  Parse a `ps -axro pid,pcpu,comm` (macOS) or `ps -axo pid,pcpu,comm`
  (Linux) line into `{pid, pct, comm}`. Filters out rows with `0.0%`
  CPU since they don't usefully contribute to the "what's hogging
  the box" view.
  """
  @spec top_line(String.t()) :: {integer(), float(), String.t()} | nil
  def top_line(line) do
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

  @doc "Parse one line of PowerShell `Format-Table -HideTableHeaders` output (`name cpu`)."
  @spec windows_top_line(String.t()) :: {float(), String.t()} | nil
  def windows_top_line(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 2) do
      [name, pct] ->
        case Float.parse(pct) do
          {p, _} -> {p, name}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Defensive `Float.parse/1` — returns 0.0 on garbage."
  @spec parse_float(String.t()) :: float()
  def parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      _ -> 0.0
    end
  end

  @doc "Format `:os.version/0` tuples as `a.b.c`."
  @spec tuple_to_dotted(tuple() | term()) :: String.t()
  def tuple_to_dotted({a, b, c}), do: "#{a}.#{b}.#{c}"
  def tuple_to_dotted(other), do: inspect(other)

  @doc """
  Read `lowpowermode N` out of `pmset -g`. Returns `:on`, `:off`,
  or `:unknown` when the field is missing or malformed.
  """
  @spec lowpowermode(String.t()) :: :on | :off | :unknown
  def lowpowermode(pmset_g) do
    case Regex.run(~r/lowpowermode\s+(\d)/, pmset_g) do
      [_, "1"] -> :on
      [_, "0"] -> :off
      _ -> :unknown
    end
  end

  @doc "Parse the percentage from `memory_pressure` output. `nil` when malformed."
  @spec memory_pressure_pct(String.t()) :: integer() | nil
  def memory_pressure_pct(out) do
    case Regex.run(~r/System-wide memory free percentage:\s+(\d+)/, out) do
      [_, pct_s] -> String.to_integer(pct_s)
      _ -> nil
    end
  end

  @doc "Read the `[active]` mode from `/sys/kernel/mm/transparent_hugepage/enabled`."
  @spec thp_active(String.t()) :: String.t()
  def thp_active(raw) do
    case Regex.run(~r/\[(\w+)\]/, raw) do
      [_, val] -> val
      _ -> "unknown"
    end
  end

  @doc "Classify `pmset -g batt` output."
  @spec power_source(String.t()) :: :ac | :battery | :unknown
  def power_source(out) do
    cond do
      String.contains?(out, "AC Power") -> :ac
      String.contains?(out, "Battery Power") -> :battery
      true -> :unknown
    end
  end

  @doc "Classify Windows `powercfg /getactivescheme` output."
  @spec power_plan(String.t()) :: :high | :balanced | :saver | :other
  def power_plan(out) do
    cond do
      String.contains?(out, "High performance") or
          String.contains?(out, "Ultimate Performance") ->
        :high

      String.contains?(out, "Balanced") ->
        :balanced

      String.contains?(out, "Power saver") ->
        :saver

      true ->
        :other
    end
  end

  @doc "Classify `mdutil -s /` output."
  @spec spotlight_state(String.t()) :: :indexing | :idle | :disabled | :unknown
  def spotlight_state(out) do
    cond do
      String.contains?(out, "Indexing in progress") -> :indexing
      String.contains?(out, "Indexing enabled") -> :idle
      String.contains?(out, "Indexing disabled") -> :disabled
      true -> :unknown
    end
  end

  @doc "Classify `tmutil status` output."
  @spec time_machine_state(String.t()) :: :running | :idle | :unknown
  def time_machine_state(out) do
    cond do
      String.contains?(out, "Running = 1") -> :running
      String.contains?(out, "Running = 0") -> :idle
      true -> :unknown
    end
  end

  @doc "Find a named field in `/proc/cpuinfo`. Returns the trimmed value or nil."
  @spec cpuinfo_field(String.t(), String.t()) :: String.t() | nil
  def cpuinfo_field(content, field) do
    content
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

  @doc "Count `processor` lines in `/proc/cpuinfo`."
  @spec cpuinfo_count(String.t()) :: integer()
  def cpuinfo_count(content) do
    content
    |> String.split("\n")
    |> Enum.count(fn line -> String.starts_with?(line, "processor") end)
  end

  # ===================================================================
  # Threshold judgements
  # ===================================================================

  @doc "Load-average judgement, shared by macOS and Linux."
  @spec judge_load_avg(float(), pos_integer()) :: check()
  def judge_load_avg(l1f, cores) when cores > 0 do
    ratio = l1f / cores
    rounded = Float.round(ratio, 2)

    cond do
      ratio < 0.3 ->
        {:ok, "Load average", "1m=#{l1f} (#{rounded}× cores)", nil}

      ratio < 0.7 ->
        {:info, "Load average", "1m=#{l1f} (#{rounded}× cores) — moderate", nil}

      true ->
        {:warn, "Load average high",
         "1m=#{l1f} on #{cores} cores (#{rounded}× saturation)",
         "wait for current workload to finish or close CPU-heavy apps"}
    end
  end

  @doc "macOS `memory_pressure` judgement."
  @spec judge_memory_pressure(integer()) :: check()
  def judge_memory_pressure(pct) when is_integer(pct) do
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
  end

  @doc "Linux swap judgement from `/proc/meminfo` totals."
  @spec judge_swap(integer(), integer()) :: check()
  def judge_swap(total_kb, free_kb) do
    used_kb = total_kb - free_kb

    cond do
      total_kb == 0 ->
        {:ok, "Swap", "no swap configured", nil}

      used_kb < 32 * 1024 ->
        {:ok, "Swap", "swap configured but unused", nil}

      true ->
        used_mb = used_kb / 1024

        {:warn, "Swap in use",
         "#{Float.round(used_mb, 0)} MB swapped — disk paging will spike timings",
         "free memory or sudo swapoff -a (will require sufficient RAM)"}
    end
  end

  @doc "Linux MemAvailable judgement (input in kB)."
  @spec judge_linux_free_memory(integer()) :: check()
  def judge_linux_free_memory(avail_kb) do
    cond do
      avail_kb == 0 ->
        {:skip, "Free memory", "MemAvailable not reported", nil}

      avail_kb < 1 * 1024 * 1024 ->
        {:warn, "Low free memory",
         "only #{Float.round(avail_kb / 1024 / 1024, 2)} GB available",
         "close memory-heavy apps before measuring"}

      true ->
        {:ok, "Free memory", "#{Float.round(avail_kb / 1024 / 1024, 1)} GB available", nil}
    end
  end

  @doc "Windows page-file judgement (input in MB)."
  @spec judge_windows_pagefile(integer()) :: check()
  def judge_windows_pagefile(mb) do
    cond do
      mb < 32 ->
        {:ok, "Page file", "no significant usage", nil}

      mb < 256 ->
        {:info, "Page file", "#{mb} MB in use — modest", nil}

      true ->
        {:warn, "Page file in active use",
         "#{mb} MB paged out — disk paging will spike timings",
         "close memory-heavy apps before measuring"}
    end
  end

  @doc "Windows FreePhysicalMemory judgement (input in kB)."
  @spec judge_windows_free_memory(integer()) :: check()
  def judge_windows_free_memory(kb) do
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
  end

  @doc "Windows total CPU usage judgement (already-cooked Get-Counter percent)."
  @spec judge_windows_cpu(float()) :: check()
  def judge_windows_cpu(pct) do
    rounded = Float.round(pct, 1)

    cond do
      pct < 15 ->
        {:ok, "Total CPU usage", "#{rounded}%", nil}

      pct < 40 ->
        {:info, "Total CPU usage", "#{rounded}% — moderate", nil}

      true ->
        {:warn, "High total CPU usage",
         "#{rounded}% in use system-wide before benchmarking",
         "close CPU-heavy apps; check Task Manager"}
    end
  end

  @doc """
  Linux CPU governor judgement. Inputs are the trimmed governor
  strings from each `cpufreq/scaling_governor`. Mixed governors are
  treated as a warn since *any* core scaling down is enough to
  perturb steady-state timing.
  """
  @spec judge_governor([String.t()]) :: check()
  def judge_governor(govs) do
    case Enum.uniq(govs) do
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

  @doc """
  Top-CPU-process judgement. Input is `[{pct, name}]` already filtered
  for the current process. Buckets by aggregate background load.
  """
  @spec judge_top([{float(), String.t()}]) :: check()
  def judge_top([]), do: {:ok, "Top CPU processes", "nothing notable", nil}

  def judge_top(top) do
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
        {:ok, "Top CPU processes",
         "background usage trivial (sum #{Float.round(total, 1)}%)", nil}

      total < 25.0 ->
        {:info, "Top CPU processes", "moderate (top: #{biggest})", nil}

      true ->
        {:warn, "High background CPU usage", "top procs: #{biggest}",
         "close CPU-heavy apps before measuring"}
    end
  end
end
