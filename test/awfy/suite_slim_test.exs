# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.SuiteSlimTest do
  use ExUnit.Case, async: true

  alias Awfy.SuiteSlim

  describe "slim/1" do
    test "drops samples on every CollectionData field of every scenario" do
      suite = %Benchee.Suite{
        scenarios: [
          fixture_scenario(samples_n: 5),
          fixture_scenario(samples_n: 7)
        ]
      }

      slim = SuiteSlim.slim(suite)

      Enum.each(slim.scenarios, fn s ->
        assert s.run_time_data.samples == []
        assert s.memory_usage_data.samples == []
        assert s.reductions_data.samples == []
      end)
    end

    test "preserves the scalar Statistics fields the dashboard reads" do
      stats = %Benchee.Statistics{
        average: 1234.5,
        median: 1200.0,
        std_dev: 50.0,
        sample_size: 999,
        percentiles: %{50 => 1200.0, 99 => 1300.0},
        # Outliers must still be cleared — see test below; this case
        # only proves the *scalar* fields survive the slim.
        outliers: [99_999, 100_000]
      }

      suite = %Benchee.Suite{
        scenarios: [
          fixture_scenario(samples_n: 10) |> put_stats(stats)
        ]
      }

      [s] = SuiteSlim.slim(suite).scenarios
      slimmed_stats = s.run_time_data.statistics

      assert slimmed_stats.average == stats.average
      assert slimmed_stats.median == stats.median
      assert slimmed_stats.std_dev == stats.std_dev
      assert slimmed_stats.sample_size == stats.sample_size
      assert slimmed_stats.percentiles == stats.percentiles
    end

    test "clears Statistics.outliers — the dominant size on sub-µs benchmarks" do
      # Real-world fixture: one ETS scenario at OTP 28 had 3.6 MB
      # of outlier samples *after* we'd already cleared
      # CollectionData.samples. The outlier list is what made the
      # slim insufficient on its own. Lock the behaviour so a
      # future Benchee version that grows additional sample-shaped
      # fields trips this test instead of silently re-bloating
      # gh-pages.
      bloated_outliers = Enum.to_list(1..1_000)

      stats = %Benchee.Statistics{
        median: 42.0,
        sample_size: 1_000_000,
        outliers: bloated_outliers
      }

      suite = %Benchee.Suite{
        scenarios: [fixture_scenario(samples_n: 0) |> put_stats(stats)]
      }

      [s] = SuiteSlim.slim(suite).scenarios
      assert s.run_time_data.statistics.outliers == []
      # Other stats survive intact.
      assert s.run_time_data.statistics.median == 42.0
      assert s.run_time_data.statistics.sample_size == 1_000_000
    end

    test "preserves scenario metadata (name / input_name / tag)" do
      suite = %Benchee.Suite{
        scenarios: [
          %{
            fixture_scenario(samples_n: 3)
            | name: "phash2/atom",
              input_name: "atom",
              tag: "test-1"
          }
        ]
      }

      [slim_s] = SuiteSlim.slim(suite).scenarios
      assert slim_s.name == "phash2/atom"
      assert slim_s.input_name == "atom"
      assert slim_s.tag == "test-1"
    end

    test "clears scenario.input and configuration.inputs" do
      # iolist_size's `huge_16mb` ships a 16 MB binary as the input
      # value on every scenario. The dashboard reads `input_name`
      # (the map key) but not the value, so dropping the value cuts
      # tens of MB per file with no observable impact.
      huge = :binary.copy(<<0>>, 16 * 1024 * 1024)

      suite = %Benchee.Suite{
        configuration: %Benchee.Configuration{inputs: %{"huge" => huge}},
        scenarios: [
          %{fixture_scenario(samples_n: 3) | input_name: "huge", input: huge}
        ]
      }

      slim = SuiteSlim.slim(suite)
      assert slim.configuration.inputs == nil
      assert hd(slim.scenarios).input == nil
      assert hd(slim.scenarios).input_name == "huge"
    end

    test "term_to_binary of slim suite is dramatically smaller than the original" do
      # Fixture: 100k samples per scenario × 5 scenarios ≈ what a
      # single phash2 family looks like on disk. Slim should cut
      # the binary by orders of magnitude — we assert at least 100×
      # to leave headroom for fixture overhead while still failing
      # loudly if the slim fields ever drift out of sync with the
      # Benchee struct shape (which would silently leave samples in).
      scenarios = for _ <- 1..5, do: fixture_scenario(samples_n: 100_000)
      big = %Benchee.Suite{scenarios: scenarios}

      slim = SuiteSlim.slim(big)

      big_size = byte_size(:erlang.term_to_binary(big))
      slim_size = byte_size(:erlang.term_to_binary(slim))

      assert slim_size * 100 < big_size,
             "expected slim to be ≥100× smaller; got #{slim_size}/#{big_size} bytes"
    end
  end

  defp fixture_scenario(samples_n: n) do
    samples = if n > 0, do: Enum.to_list(1..n), else: []

    %Benchee.Scenario{
      name: "fixture",
      job_name: "fixture",
      function: fn -> :ok end,
      input_name: nil,
      input: nil,
      run_time_data: %Benchee.CollectionData{samples: samples, statistics: %Benchee.Statistics{}},
      memory_usage_data: %Benchee.CollectionData{samples: samples},
      reductions_data: %Benchee.CollectionData{samples: samples}
    }
  end

  defp put_stats(%Benchee.Scenario{} = s, %Benchee.Statistics{} = stats) do
    %{s | run_time_data: %{s.run_time_data | statistics: stats}}
  end
end
