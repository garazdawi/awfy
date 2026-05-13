# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.RunContext do
  use ExUnit.Case, async: true

  alias Awfy.RunContext

  describe "new/1" do
    test "builds a context with the required fields populated" do
      ctx = RunContext.new(scenario: :synthetic, env: fn _ -> nil end)

      assert ctx.scenario == :synthetic
      assert is_binary(ctx.otp_label) and ctx.otp_label != ""
      assert is_binary(ctx.otp_release)
      assert is_binary(ctx.elixir_version)
      assert ctx.emu_flavor in [:jit, :emu]
      assert ctx.flavor_source in [:label, :runtime]
      assert is_integer(ctx.schedulers) and ctx.schedulers > 0
      assert %DateTime{} = ctx.trend_timestamp
      assert is_binary(ctx.git_sha)
      assert is_boolean(ctx.git_dirty)
      assert is_binary(ctx.label) and ctx.label != ""
    end

    test "label override wins over auto_label" do
      ctx = RunContext.new(scenario: :synthetic, label: "explicit-label", env: fn _ -> nil end)
      assert ctx.label == "explicit-label"
    end

    test "env override picks up AWFY_OTP_VERSION" do
      env = fn
        "AWFY_OTP_VERSION" -> "21.3"
        _ -> nil
      end

      ctx = RunContext.new(scenario: :synthetic, env: env)
      assert ctx.otp_label == "21.3"
    end

    test "elixir_version honours AWFY_TARGET_ELIXIR_VERSION" do
      env = fn
        "AWFY_TARGET_ELIXIR_VERSION" -> "1.11.4"
        _ -> nil
      end

      ctx = RunContext.new(scenario: :synthetic, env: env)
      assert ctx.elixir_version == "1.11.4"
    end

    test "label-suffix flavor wins over runtime flavor" do
      ctx =
        RunContext.new(scenario: :xmpp, label: "abc123-test-linux-x86_64-emu", env: fn _ -> nil end)

      assert ctx.emu_flavor == :emu
      assert ctx.flavor_source == :label
    end

    test "no label suffix falls back to runtime emu flavor" do
      ctx = RunContext.new(scenario: :synthetic, label: "v1", env: fn _ -> nil end)
      assert ctx.flavor_source == :runtime
    end

    test "scenario tag is captured verbatim" do
      assert %RunContext{scenario: :xmpp} = RunContext.new(scenario: :xmpp, env: fn _ -> nil end)
      assert %RunContext{scenario: :otp_benchmarks} = RunContext.new(scenario: :otp_benchmarks, env: fn _ -> nil end)
    end
  end

  describe "resolve_emu_flavor/1" do
    test "jit suffix" do
      assert {:jit, :label} = RunContext.resolve_emu_flavor("abc-test-linux-arm64-jit")
    end

    test "emu suffix" do
      assert {:emu, :label} = RunContext.resolve_emu_flavor("abc-test-linux-arm64-emu")
    end

    test "no recognised suffix falls back to runtime" do
      assert {_, :runtime} = RunContext.resolve_emu_flavor("v1")
      assert {_, :runtime} = RunContext.resolve_emu_flavor("")
    end

    test "nil label falls back to runtime" do
      assert {_, :runtime} = RunContext.resolve_emu_flavor(nil)
    end
  end
end
