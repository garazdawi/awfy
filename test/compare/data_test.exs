# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Compare.DataTest do
  @moduledoc """
  Tests the pure data transforms in `Awfy.Compare.Data`. The
  geomean-of-ratios is the suite-wide aggregate metric we surface
  on the dashboard; getting it wrong corrupts the headline number
  on every release comparison, in subtle ways.
  """

  use ExUnit.Case, async: true

  alias Awfy.Compare.Data

  defp row(opts) do
    # Use Keyword.get/3 (not `opts[:k] || default`) so explicit `nil`
    # in opts stays nil — the `||` operator coerces nil to the default.
    Map.new([
      {:label, Keyword.get(opts, :label, "v1")},
      {:timestamp, Keyword.get(opts, :timestamp, "20260101T0900")},
      {:otp, Keyword.get(opts, :otp, "28")},
      {:elixir, Keyword.get(opts, :elixir, "1.19.5")},
      {:hostname, Keyword.get(opts, :hostname, "h1")},
      {:cpu, Keyword.get(opts, :cpu, "Apple M5")},
      {:arch, Keyword.get(opts, :arch, "aarch64-apple-darwin")},
      {:cores, Keyword.get(opts, :cores, 10)},
      {:emu_flavor, Keyword.get(opts, :emu_flavor, "jit")},
      {:schedulers_online, Keyword.get(opts, :schedulers_online, 10)},
      {:lang, Keyword.get(opts, :lang, "erlang")},
      {:input, Keyword.get(opts, :input)},
      {:benchmark, Keyword.get(opts, :benchmark, "Bounce")},
      {:median_ms, Keyword.get(opts, :median_ms, 100.0)},
      {:mean_ms, Keyword.get(opts, :mean_ms, 100.0)},
      {:stddev_ms, Keyword.get(opts, :stddev_ms, 1.0)},
      {:samples_n, Keyword.get(opts, :samples_n, 10)},
      {:inner_iter, Keyword.get(opts, :inner_iter, 1500)},
      {:source_sha256, Keyword.get(opts, :source_sha256)},
      {:verified, Keyword.get(opts, :verified, true)}
    ])
  end

  describe "geomean_ratio/2" do
    test "1.0 when label and baseline are identical" do
      rows = [
        row(benchmark: "Bounce", median_ms: 100.0),
        row(benchmark: "List", median_ms: 200.0),
        row(benchmark: "NBody", median_ms: 50.0)
      ]

      assert {gm, []} = Data.geomean_ratio(rows, rows)
      assert_in_delta gm, 1.0, 0.0001
    end

    test "label 2× slower → geomean 2.0" do
      base = [
        row(benchmark: "Bounce", median_ms: 100.0),
        row(benchmark: "List", median_ms: 200.0),
        row(benchmark: "NBody", median_ms: 50.0)
      ]

      label =
        Enum.map(base, fn r -> %{r | median_ms: r.median_ms * 2} end)

      assert {2.0, []} = Data.geomean_ratio(label, base)
    end

    test "geomean is geometric, not arithmetic" do
      # arith mean of {2.0, 0.5, 1.0} = 1.166…
      # geom  mean of {2.0, 0.5, 1.0} = exp(mean(ln 2 + ln 0.5 + ln 1)) = 1.0
      base = [
        row(benchmark: "A", median_ms: 100.0),
        row(benchmark: "B", median_ms: 100.0),
        row(benchmark: "C", median_ms: 100.0)
      ]

      label = [
        row(benchmark: "A", median_ms: 200.0),
        row(benchmark: "B", median_ms: 50.0),
        row(benchmark: "C", median_ms: 100.0)
      ]

      assert {gm, []} = Data.geomean_ratio(label, base)
      assert_in_delta gm, 1.0, 0.0001
    end

    test "intersection-only — non-overlapping benches dropped + reported" do
      base = [
        row(benchmark: "A", median_ms: 100.0),
        row(benchmark: "B", median_ms: 100.0),
        row(benchmark: "Z_only_in_base", median_ms: 100.0)
      ]

      label = [
        row(benchmark: "A", median_ms: 100.0),
        row(benchmark: "B", median_ms: 100.0),
        row(benchmark: "Y_only_in_label", median_ms: 100.0)
      ]

      assert {gm, dropped} = Data.geomean_ratio(label, base)
      assert_in_delta gm, 1.0, 0.0001
      assert dropped == ["Y_only_in_label", "Z_only_in_base"]
    end

    test "no overlap → {nil, all_dropped}" do
      base = [row(benchmark: "Only-base", median_ms: 100.0)]
      label = [row(benchmark: "Only-label", median_ms: 100.0)]

      assert {nil, ["Only-base", "Only-label"]} = Data.geomean_ratio(label, base)
    end

    test "rows with missing median_ms are filtered before indexing" do
      base = [row(benchmark: "A", median_ms: 100.0), row(benchmark: "B", median_ms: nil)]
      label = [row(benchmark: "A", median_ms: 200.0), row(benchmark: "B", median_ms: 200.0)]

      # B has no median_ms in baseline → dropped from intersection. Only A matched.
      assert {gm, dropped} = Data.geomean_ratio(label, base)
      assert_in_delta gm, 2.0, 0.0001
      assert dropped == ["B"]
    end

    test "multi-input families contribute one geomean-of-inputs cell each" do
      # phash2's two inputs collapse to a single per-family cell
      # whose value is the geomean of the per-input medians. That
      # cell weighs equally with Bounce in the suite-wide ratio.
      # Without folding, phash2 would have dominated 2:1 against
      # AWFY 1-cell benchmarks — or been dropped entirely under
      # the previous reject_multi_input policy.
      base = [
        row(benchmark: "Bounce", median_ms: 100.0),
        row(benchmark: "phash2", lang: nil, input: "atom", median_ms: 100.0),
        row(benchmark: "phash2", lang: nil, input: "binary_4k", median_ms: 400.0)
      ]

      # Bounce 2× slower; phash2 unchanged per-input.
      label = [
        row(benchmark: "Bounce", median_ms: 200.0),
        row(benchmark: "phash2", lang: nil, input: "atom", median_ms: 100.0),
        row(benchmark: "phash2", lang: nil, input: "binary_4k", median_ms: 400.0)
      ]

      assert {gm, []} = Data.geomean_ratio(label, base)
      # Bounce ratio = 2.0, phash2 family ratio = (200/200) = 1.0.
      # Suite geomean = sqrt(2.0 × 1.0) = √2.
      assert_in_delta gm, :math.sqrt(2.0), 0.0001
    end

    test "multi-input families with uniform per-input drift propagate cleanly" do
      base = [
        row(benchmark: "Bounce", median_ms: 100.0),
        row(benchmark: "phash2", lang: nil, input: "atom", median_ms: 50.0),
        row(benchmark: "phash2", lang: nil, input: "binary", median_ms: 200.0)
      ]

      # Both Bounce and every phash2 input 2× slower → suite ratio 2.0.
      label = Enum.map(base, fn r -> %{r | median_ms: r.median_ms * 2} end)

      assert {gm, []} = Data.geomean_ratio(label, base)
      assert_in_delta gm, 2.0, 0.0001
    end

    test "when both langs present, indexes by Erlang first" do
      # Same benchmark from both langs — ratio uses the Erlang row.
      base = [
        row(benchmark: "A", lang: "erlang", median_ms: 100.0),
        row(benchmark: "A", lang: "elixir", median_ms: 200.0)
      ]

      label = [
        row(benchmark: "A", lang: "erlang", median_ms: 200.0),
        row(benchmark: "A", lang: "elixir", median_ms: 200.0)
      ]

      assert {gm, []} = Data.geomean_ratio(label, base)
      # erlang/erlang: 200/100 = 2.0
      assert_in_delta gm, 2.0, 0.0001
    end
  end

  describe "load/2" do
    test "returns empty result on a non-existent root" do
      assert %{runs: [], rows: []} = Data.load("/tmp/awfy-doesnt-exist-#{System.unique_integer()}")
    end

    test "returns empty result on a directory with no run-dirs" do
      tmp = "tmp/awfy_load_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "stray-file.txt"), "not a run dir")
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert %{runs: [], rows: []} = Data.load(tmp)
    end
  end
end
