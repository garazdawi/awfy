# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.Measure.ScenarioNames do
  @moduledoc """
  Pin the family of scenario-name patterns the three measurement
  paths produce. `Awfy.Compare.Data.identify_scenario/3` parses
  these to recover `{benchmark, lang}` for each row; a silent
  rename or format drift in any writer would otherwise demote rows
  to `lang: nil` in the dashboard (see data.ex:280–300 for the
  legacy-bundle bug history).

  PLAN/INFRA_REFACTOR.md § 7.
  """

  use ExUnit.Case, async: true

  alias Awfy.Compare.Data

  @awfy_pattern ~r/^[A-Z][A-Za-z0-9]+\/(erlang|elixir)$/
  @otp_bench_family_pattern ~r/^[a-z][a-z0-9_]+$/
  @xmpp_pattern ~r/^xmpp_(cpu|mem|speed)\/erlang$/

  describe "Awfy.Compare.Data.identify_scenario/3" do
    test "modern AWFY scenarios decode as {Benchmark, lang}" do
      assert {"Bounce", "erlang"} = Data.identify_scenario("Bounce/erlang", "Bounce", %{})
      assert {"CD", "elixir"} = Data.identify_scenario("CD/elixir", "CD", %{})
    end

    test "modern XMPP scenarios decode as {xmpp_<metric>, erlang}" do
      assert {"xmpp_cpu", "erlang"} = Data.identify_scenario("xmpp_cpu/erlang", "xmpp_cpu", %{})
      assert {"xmpp_mem", "erlang"} = Data.identify_scenario("xmpp_mem/erlang", "xmpp_mem", %{})
      assert {"xmpp_speed", "erlang"} = Data.identify_scenario("xmpp_speed/erlang", "xmpp_speed", %{})
    end

    test "legacy bundle-mode scenario name (bare module) recovers lang from languages meta" do
      # The bundle path emits raw module names. The lookup table in
      # the per-bench meta maps each lang to its module name; we
      # recover lang from there and pair with the bench_name (the
      # filename's base).
      languages = %{
        "erlang" => %{"module" => "awfy_bounce"},
        "elixir" => %{"module" => "Elixir.Awfy.Benchmarks.Bounce"}
      }

      assert {"Bounce", "erlang"} = Data.identify_scenario("awfy_bounce", "Bounce", languages)
    end

    test "legacy Elixir bundle-mode (stripped prefix) recovers lang too" do
      # Benchee strips the `Elixir.` prefix when rendering scenario
      # names — `identify_scenario/3` must check both forms.
      languages = %{
        "elixir" => %{"module" => "Elixir.Awfy.Benchmarks.Bounce"}
      }

      assert {"Bounce", "elixir"} = Data.identify_scenario("Awfy.Benchmarks.Bounce", "Bounce", languages)
    end

    test "unrecognised scenario name returns {nil, nil}" do
      assert {nil, nil} = Data.identify_scenario("totally_unknown_thing", "anything", %{})
    end
  end

  describe "pattern regression — pin the format of names produced" do
    # These regexes encode the *write-side* contract every measure
    # task must honour. If a future writer emits a name that doesn't
    # match any of these patterns, the dashboard will silently
    # demote the row to `lang: nil`. Catch the format drift here so
    # the failure is at write time, not dashboard time.

    test "AWFY pattern matches the modern shape" do
      assert "Bounce/erlang" =~ @awfy_pattern
      assert "CD/elixir" =~ @awfy_pattern
      assert "DeltaBlue/erlang" =~ @awfy_pattern
      refute "bounce/erlang" =~ @awfy_pattern, "lowercase-first should be the OtpBenchmarks shape"
      refute "Bounce" =~ @awfy_pattern, "missing /<lang> suffix should not match"
    end

    test "OtpBenchmarks family-name pattern matches the modern shape" do
      assert "phash2" =~ @otp_bench_family_pattern
      assert "term_to_binary" =~ @otp_bench_family_pattern
      refute "PHash2" =~ @otp_bench_family_pattern, "capitalised should be AWFY-shape"
    end

    test "XMPP pattern matches the renamed shape" do
      assert "xmpp_cpu/erlang" =~ @xmpp_pattern
      assert "xmpp_mem/erlang" =~ @xmpp_pattern
      assert "xmpp_speed/erlang" =~ @xmpp_pattern
      refute "xmpp_throughput/erlang" =~ @xmpp_pattern, "throughput was renamed to speed"
      refute "dynamic_domains_pm_cpu_pct/erlang" =~ @xmpp_pattern, "old long name should not match"
    end
  end
end
