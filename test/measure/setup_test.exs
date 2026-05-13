# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyTest.Measure.Setup do
  use ExUnit.Case, async: false

  alias Awfy.Measure.Setup

  setup do
    dir = Path.join("tmp", "setup_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, root: dir}
  end

  describe "out_root/1" do
    test "honours --out" do
      assert Setup.out_root(out: "custom_dir") == "custom_dir"
    end

    test "defaults to 'results' when absent" do
      assert Setup.out_root([]) == "results"
    end
  end

  describe "prepare/2" do
    test "creates the run-dir under out_root", %{root: root} do
      {:ok, ctx, dir} = Setup.prepare([out: root, label: "v1"], :synthetic)
      assert ctx.label == "v1"
      assert File.dir?(dir)
      assert String.starts_with?(dir, root)
    end

    test "scenario_tag flows through to the RunContext", %{root: root} do
      {:ok, ctx, _dir} = Setup.prepare([out: root, label: "v1"], :xmpp)
      assert ctx.scenario == :xmpp
    end

    test "existing dir is rebuilt without --no-clobber", %{root: root} do
      {:ok, _ctx, dir} = Setup.prepare([out: root, label: "v1"], :synthetic)
      File.write!(Path.join(dir, "stale.txt"), "leftover")

      # Re-prep against the same label — Mix.shell sends the warn
      # info to its own channel which CaptureIO at :user doesn't
      # see; assert on the rebuild side-effect (stale file gone)
      # instead of the message.
      {:ok, _ctx, dir2} = Setup.prepare([out: root, label: "v1"], :synthetic)
      assert dir == dir2
      refute File.exists?(Path.join(dir, "stale.txt"))
    end

    test "existing dir + --no-clobber raises", %{root: root} do
      {:ok, _ctx, _dir} = Setup.prepare([out: root, label: "v1"], :synthetic)

      assert_raise Mix.Error, ~r/exists and --no-clobber set/, fn ->
        Setup.prepare([out: root, label: "v1", no_clobber: true], :synthetic)
      end
    end
  end
end
