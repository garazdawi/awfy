# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Preflight.ParseTest do
  @moduledoc """
  Tests for the regex/threshold logic in `Awfy.Preflight.Parse`. Each
  judgement bucket is verified at its boundary so a silent threshold
  drift (e.g. 25% → 20%) gets caught by CI rather than discovered the
  next time a benchmark night looks weird.

  Captured-output fixtures are inlined as heredocs to avoid the
  cross-platform tool dependency that's the whole point of extracting
  these parsers.
  """

  use ExUnit.Case, async: true

  alias Awfy.Preflight.Parse

  # ===================================================================
  # Low-level parsers
  # ===================================================================

  describe "meminfo_kb/2" do
    @meminfo """
    MemTotal:       16384000 kB
    MemFree:         1024000 kB
    MemAvailable:    4096000 kB
    SwapTotal:       2048000 kB
    SwapFree:        2048000 kB
    """

    test "extracts kB by key" do
      assert Parse.meminfo_kb(@meminfo, "MemTotal") == 16_384_000
      assert Parse.meminfo_kb(@meminfo, "MemAvailable") == 4_096_000
      assert Parse.meminfo_kb(@meminfo, "SwapTotal") == 2_048_000
    end

    test "missing key → 0 (callers branch on this)" do
      assert Parse.meminfo_kb(@meminfo, "DoesNotExist") == 0
      assert Parse.meminfo_kb("", "MemTotal") == 0
    end
  end

  describe "top_line/1" do
    test "ps line: pid pcpu comm" do
      assert Parse.top_line("  1234  12.5 firefox") == {1234, 12.5, "firefox"}
    end

    test "comm with spaces is preserved (parts: 3)" do
      assert Parse.top_line("  1234  12.5 some app") == {1234, 12.5, "some app"}
    end

    test "0.0% rows are filtered (sentinel for idle process)" do
      assert Parse.top_line("  1234  0.0 idleproc") == nil
    end

    test "header line → nil" do
      assert Parse.top_line("PID  %CPU COMM") == nil
    end

    test "garbage → nil" do
      assert Parse.top_line("") == nil
      assert Parse.top_line("not even close") == nil
    end
  end

  describe "windows_top_line/1" do
    test "Format-Table line: name cpu" do
      assert Parse.windows_top_line("chrome      45.2") == {45.2, "chrome"}
    end

    test "non-numeric cpu → nil" do
      assert Parse.windows_top_line("chrome      abc") == nil
    end

    test "single column → nil" do
      assert Parse.windows_top_line("chrome") == nil
    end
  end

  describe "parse_float/1" do
    test "parses prefix" do
      assert Parse.parse_float("1.5") == 1.5
      assert Parse.parse_float("0.25 cores") == 0.25
    end

    test "garbage → 0.0 (defensive default)" do
      assert Parse.parse_float("nope") == 0.0
      assert Parse.parse_float("") == 0.0
    end
  end

  describe "tuple_to_dotted/1" do
    test "3-tuple → a.b.c" do
      assert Parse.tuple_to_dotted({23, 4, 0}) == "23.4.0"
    end

    test "non-3-tuple → inspect fallback" do
      assert Parse.tuple_to_dotted({1, 2}) == "{1, 2}"
    end
  end

  describe "lowpowermode/1" do
    test ":on / :off / :unknown" do
      assert Parse.lowpowermode("foo\nlowpowermode         1\nbar") == :on
      assert Parse.lowpowermode("foo\nlowpowermode         0\nbar") == :off
      assert Parse.lowpowermode("no such key here") == :unknown
    end
  end

  describe "memory_pressure_pct/1" do
    test "extracts percentage" do
      out = """
      System-wide memory free percentage: 73%
      """

      assert Parse.memory_pressure_pct(out) == 73
    end

    test "missing → nil" do
      assert Parse.memory_pressure_pct("nothing here") == nil
    end
  end

  describe "thp_active/1" do
    test "extracts the [bracketed] mode" do
      assert Parse.thp_active("always [madvise] never") == "madvise"
    end

    test "no brackets → unknown" do
      assert Parse.thp_active("garbage") == "unknown"
    end
  end

  describe "power_source/1" do
    test "AC / Battery / unknown" do
      assert Parse.power_source("Now drawing from 'AC Power'") == :ac
      assert Parse.power_source("Now drawing from 'Battery Power'") == :battery
      assert Parse.power_source("???") == :unknown
    end
  end

  describe "power_plan/1" do
    test "high / balanced / saver / other" do
      assert Parse.power_plan("Power Scheme GUID: ... (High performance)") == :high
      assert Parse.power_plan("Power Scheme GUID: ... (Ultimate Performance)") == :high
      assert Parse.power_plan("Power Scheme GUID: ... (Balanced)") == :balanced
      assert Parse.power_plan("Power Scheme GUID: ... (Power saver)") == :saver
      assert Parse.power_plan("Some Custom Scheme") == :other
    end
  end

  describe "spotlight_state/1" do
    test "indexing / idle / disabled / unknown" do
      assert Parse.spotlight_state("/:\n        Indexing in progress.") == :indexing
      assert Parse.spotlight_state("/:\n        Indexing enabled.") == :idle
      assert Parse.spotlight_state("/:\n        Indexing disabled.") == :disabled
      assert Parse.spotlight_state("???") == :unknown
    end
  end

  describe "time_machine_state/1" do
    test "running / idle / unknown" do
      assert Parse.time_machine_state("Running = 1") == :running
      assert Parse.time_machine_state("Running = 0") == :idle
      assert Parse.time_machine_state("???") == :unknown
    end
  end

  describe "cpuinfo_field/2 + cpuinfo_count/1" do
    @cpuinfo """
    processor       : 0
    model name      : Intel(R) Xeon(R) Gold 6126
    cpu MHz         : 2600.000
    processor       : 1
    model name      : Intel(R) Xeon(R) Gold 6126
    """

    test "first matching field" do
      assert Parse.cpuinfo_field(@cpuinfo, "model name") ==
               "Intel(R) Xeon(R) Gold 6126"
    end

    test "missing field → nil" do
      assert Parse.cpuinfo_field(@cpuinfo, "magic flux capacitor") == nil
    end

    test "count counts processor: lines" do
      assert Parse.cpuinfo_count(@cpuinfo) == 2
    end
  end

  # ===================================================================
  # Threshold judgements
  # ===================================================================

  describe "judge_load_avg/2" do
    test "ratio < 0.3 → :ok" do
      assert {:ok, "Load average", _, nil} = Parse.judge_load_avg(2.0, 10)
    end

    test "ratio in [0.3, 0.7) → :info" do
      assert {:info, "Load average", _, nil} = Parse.judge_load_avg(5.0, 10)
    end

    test "ratio >= 0.7 → :warn" do
      assert {:warn, "Load average high", _, fix} = Parse.judge_load_avg(8.0, 10)
      assert is_binary(fix)
    end

    test "boundary at 0.3 (exactly 0.3 is :info)" do
      assert {:info, _, _, _} = Parse.judge_load_avg(3.0, 10)
    end

    test "boundary at 0.7 (exactly 0.7 is :warn)" do
      assert {:warn, _, _, _} = Parse.judge_load_avg(7.0, 10)
    end
  end

  describe "judge_memory_pressure/1" do
    test "> 25 → :ok" do
      assert {:ok, "Memory pressure", "73% free", nil} = Parse.judge_memory_pressure(73)
    end

    test "(10, 25] → :info" do
      assert {:info, "Memory pressure", _, nil} = Parse.judge_memory_pressure(20)
    end

    test "<= 10 → :warn" do
      assert {:warn, "Memory pressure high", _, _fix} = Parse.judge_memory_pressure(5)
    end

    test "boundary 25 → :info" do
      assert {:info, _, _, _} = Parse.judge_memory_pressure(25)
    end

    test "boundary 10 → :warn" do
      assert {:warn, _, _, _} = Parse.judge_memory_pressure(10)
    end
  end

  describe "judge_swap/2" do
    test "no swap configured" do
      assert {:ok, "Swap", "no swap configured", nil} = Parse.judge_swap(0, 0)
    end

    test "configured but mostly unused (< 32 MB used)" do
      total = 2_000_000
      free = total - 16 * 1024
      assert {:ok, "Swap", "swap configured but unused", nil} = Parse.judge_swap(total, free)
    end

    test "actively used → :warn with MB count" do
      total = 2_000_000
      # 100 MB used
      free = total - 100 * 1024
      assert {:warn, "Swap in use", msg, fix} = Parse.judge_swap(total, free)
      assert msg =~ "100.0 MB swapped"
      assert fix =~ "swapoff"
    end
  end

  describe "judge_linux_free_memory/1" do
    test "0 → :skip (MemAvailable not reported)" do
      assert {:skip, "Free memory", "MemAvailable not reported", nil} =
               Parse.judge_linux_free_memory(0)
    end

    test ">= 1 GB → :ok" do
      # 8 GB
      assert {:ok, "Free memory", _, nil} = Parse.judge_linux_free_memory(8 * 1024 * 1024)
    end

    test "< 1 GB → :warn" do
      # 512 MB
      assert {:warn, "Low free memory", msg, _fix} =
               Parse.judge_linux_free_memory(512 * 1024)

      assert msg =~ "0.5 GB"
    end
  end

  describe "judge_windows_pagefile/1" do
    test "< 32 MB → :ok" do
      assert {:ok, "Page file", "no significant usage", nil} = Parse.judge_windows_pagefile(0)
      assert {:ok, _, _, _} = Parse.judge_windows_pagefile(31)
    end

    test "[32, 256) → :info" do
      assert {:info, "Page file", _, nil} = Parse.judge_windows_pagefile(100)
    end

    test ">= 256 → :warn" do
      assert {:warn, "Page file in active use", _, _fix} =
               Parse.judge_windows_pagefile(512)
    end
  end

  describe "judge_windows_free_memory/1" do
    test ">= 4 GB → :ok" do
      # 8 GB
      assert {:ok, "Free memory", _, nil} =
               Parse.judge_windows_free_memory(8 * 1024 * 1024)
    end

    test "[2, 4) GB → :info" do
      # 3 GB
      assert {:info, "Free memory", _, nil} =
               Parse.judge_windows_free_memory(3 * 1024 * 1024)
    end

    test "< 2 GB → :warn" do
      # 1 GB
      assert {:warn, "Low free memory", _, _fix} =
               Parse.judge_windows_free_memory(1 * 1024 * 1024)
    end
  end

  describe "judge_windows_cpu/1" do
    test "< 15% → :ok" do
      assert {:ok, "Total CPU usage", _, nil} = Parse.judge_windows_cpu(5.0)
    end

    test "[15, 40) → :info" do
      assert {:info, "Total CPU usage", _, nil} = Parse.judge_windows_cpu(25.0)
    end

    test ">= 40 → :warn" do
      assert {:warn, "High total CPU usage", _, _fix} = Parse.judge_windows_cpu(60.0)
    end
  end

  describe "judge_governor/1" do
    test "all performance → :ok" do
      assert {:ok, "CPU governor", "all cores at performance", nil} =
               Parse.judge_governor(["performance", "performance"])
    end

    test "all powersave (single non-performance value) → :warn" do
      assert {:warn, "CPU governor not 'performance'", msg, _fix} =
               Parse.judge_governor(["powersave", "powersave"])

      assert msg =~ "powersave"
    end

    test "mixed governors → :warn (mixed)" do
      assert {:warn, "CPU governors mixed", msg, _fix} =
               Parse.judge_governor(["performance", "powersave"])

      assert msg =~ "performance"
      assert msg =~ "powersave"
    end
  end

  describe "judge_top/1" do
    test "empty → :ok" do
      assert {:ok, "Top CPU processes", "nothing notable", nil} = Parse.judge_top([])
    end

    test "trivial total (< 5%) → :ok" do
      assert {:ok, "Top CPU processes", msg, nil} =
               Parse.judge_top([{1.5, "a"}, {1.0, "b"}])

      assert msg =~ "trivial"
    end

    test "moderate (< 25%) → :info, names included" do
      assert {:info, "Top CPU processes", msg, nil} =
               Parse.judge_top([{10.0, "chrome"}, {8.0, "slack"}])

      assert msg =~ "chrome"
      assert msg =~ "slack"
    end

    test ">= 25% → :warn" do
      assert {:warn, "High background CPU usage", msg, _fix} =
               Parse.judge_top([{30.0, "chrome"}, {20.0, "video-encoder"}])

      assert msg =~ "chrome"
    end

    test "name short-circuits on slash and whitespace" do
      assert {:info, _, msg, _} = Parse.judge_top([{15.0, "/usr/bin/firefox --tab"}])
      assert msg =~ "firefox"
      refute msg =~ "/usr/bin"
      refute msg =~ "--tab"
    end
  end
end
