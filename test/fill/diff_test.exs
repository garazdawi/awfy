# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.DiffTest do
  @moduledoc """
  Tests for the platform-detect/diff logic that decides which OTP
  SHAs to measure on the current host. This is the core decision
  the fill task makes — it's worth covering because a regression
  here will quietly do nothing (or quietly run hundreds of jobs).
  """

  use ExUnit.Case, async: true

  alias Awfy.Fill.Diff

  describe "parse_run_dir/1" do
    test "well-formed run-dir → entry" do
      assert %{
               run_dir: "20260415T0930_otp28_elixir1.19.5_abc1234-macos-arm64-jit",
               timestamp: "20260415T0930",
               otp_sha: "abc1234",
               platform: "macos-arm64",
               flavor: "jit"
             } =
               Diff.parse_run_dir(
                 "20260415T0930_otp28_elixir1.19.5_abc1234-macos-arm64-jit"
               )
    end

    test "linux x86_64 emu" do
      assert %{platform: "linux-x86_64", flavor: "emu", otp_sha: "deadbee"} =
               Diff.parse_run_dir(
                 "20260415T0930_otp28_elixir1.19.5_deadbee-linux-x86_64-emu"
               )
    end

    test "non-matching name → nil (dashboard files etc. are ignored)" do
      assert Diff.parse_run_dir("index.html") == nil
      assert Diff.parse_run_dir(".nojekyll") == nil
      assert Diff.parse_run_dir("README.md") == nil
    end

    test "label without 4 parts → nil (dirty-suffix runs aren't fill candidates)" do
      assert Diff.parse_run_dir("20260415T0930_otp28_elixir1.19.5_abc-dirty_20260415T0930") ==
               nil
    end
  end

  describe "compute_missing/4" do
    setup do
      existing = [
        %{otp_sha: "sha1", platform: "linux-x86_64", flavor: "jit", timestamp: "20260415T0900"},
        %{otp_sha: "sha1", platform: "linux-x86_64", flavor: "emu", timestamp: "20260415T0900"},
        %{otp_sha: "sha1", platform: "macos-arm64", flavor: "jit", timestamp: "20260415T1000"},
        %{otp_sha: "sha2", platform: "linux-x86_64", flavor: "jit", timestamp: "20260416T0900"},
        %{otp_sha: "sha2", platform: "linux-x86_64", flavor: "emu", timestamp: "20260416T0900"}
      ]

      {:ok, existing: existing}
    end

    test "macos-arm64 missing emu for sha1, both for sha2", %{existing: existing} do
      missing = Diff.compute_missing(existing, "macos-arm64", ["jit", "emu"], nil)
      # sha2 is newer → comes first; sha2 missing both flavors; sha1 missing emu only
      assert missing == [{"sha2", "jit"}, {"sha2", "emu"}, {"sha1", "emu"}]
    end

    test "complete platform → empty", %{existing: existing} do
      assert Diff.compute_missing(existing, "linux-x86_64", ["jit", "emu"], nil) == []
    end

    test "subset of flavors", %{existing: existing} do
      assert Diff.compute_missing(existing, "macos-arm64", ["jit"], nil) == [{"sha2", "jit"}]
    end

    test "since cutoff filters out older SHAs", %{existing: existing} do
      # sha1 first seen 20260415, sha2 first seen 20260416. Cutoff 2026-04-16 keeps only sha2.
      missing = Diff.compute_missing(existing, "macos-arm64", ["jit", "emu"], "2026-04-16")
      assert missing == [{"sha2", "jit"}, {"sha2", "emu"}]
    end

    test "newest SHA sorted first regardless of input order" do
      # Reversed input order — output should still be sha2 (newer) first.
      reversed = [
        %{otp_sha: "sha1", platform: "linux-x86_64", flavor: "jit", timestamp: "20260415T0900"},
        %{otp_sha: "sha2", platform: "linux-x86_64", flavor: "jit", timestamp: "20260416T0900"}
      ]

      assert Diff.compute_missing(reversed, "macos-arm64", ["jit"], nil) == [
               {"sha2", "jit"},
               {"sha1", "jit"}
             ]
    end

    test "empty existing → nothing to fill (universe is empty)" do
      assert Diff.compute_missing([], "macos-arm64", ["jit", "emu"], nil) == []
    end
  end

  describe "filter_since/3" do
    test "nil cutoff → identity" do
      assert Diff.filter_since(["sha1"], [], nil) == ["sha1"]
    end

    test "filters by earliest sighting on any platform" do
      existing = [
        %{otp_sha: "sha1", timestamp: "20260415T0900"},
        %{otp_sha: "sha1", timestamp: "20260416T0900"},
        %{otp_sha: "sha2", timestamp: "20260417T0900"}
      ]

      # sha1 first seen 20260415, sha2 first seen 20260417. Cutoff 2026-04-16 keeps only sha2.
      assert Diff.filter_since(["sha1", "sha2"], existing, "2026-04-16") == ["sha2"]
    end
  end

  describe "detect_platform/2" do
    test "macOS arm64" do
      assert Diff.detect_platform({:unix, :darwin}, "aarch64-apple-darwin23.4.0") ==
               "macos-arm64"
    end

    test "Linux x86_64" do
      assert Diff.detect_platform({:unix, :linux}, "x86_64-pc-linux-gnu") == "linux-x86_64"
    end

    test "Windows x86_64 (win32 family ignores subname)" do
      assert Diff.detect_platform({:win32, :nt}, "win32") == "windows-win32"
      assert Diff.detect_platform({:win32, :nt}, "amd64-w64-mingw32") == "windows-x86_64"
    end

    test "unknown OS family → falls back to family-name-arch" do
      assert Diff.detect_platform({:unix, :freebsd}, "x86_64-unknown-freebsd14") ==
               "unix-freebsd-x86_64"
    end
  end

  describe "arch_string/1" do
    test "aarch64 / arm64 → arm64" do
      assert Diff.arch_string("aarch64-apple-darwin") == "arm64"
      assert Diff.arch_string("arm64-apple-darwin") == "arm64"
    end

    test "x86_64 / amd64 → x86_64" do
      assert Diff.arch_string("x86_64-pc-linux-gnu") == "x86_64"
      assert Diff.arch_string("amd64-w64-mingw32") == "x86_64"
    end

    test "unknown arch → first triple component" do
      assert Diff.arch_string("riscv64-unknown-linux-gnu") == "riscv64"
    end
  end

  describe "maybe_limit/2" do
    test "nil → identity" do
      assert Diff.maybe_limit([1, 2, 3], nil) == [1, 2, 3]
    end

    test "positive int → take" do
      assert Diff.maybe_limit([1, 2, 3, 4], 2) == [1, 2]
    end
  end

  describe "parse_csv/1" do
    test "nil → nil" do
      assert Diff.parse_csv(nil) == nil
    end

    test "splits, trims empties" do
      assert Diff.parse_csv("jit,emu") == ["jit", "emu"]
      assert Diff.parse_csv("jit,,emu,") == ["jit", "emu"]
    end
  end
end
