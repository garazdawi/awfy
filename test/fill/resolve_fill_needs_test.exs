# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.ResolveFillNeedsTest do
  @moduledoc """
  Tests for `bin/resolve-fill-needs.sh` — the resolver that turns a
  comma-separated list of expanded OTP refs into the per-(mode,
  platform) JSON arrays + has_* booleans the bench.yml workflow
  matrices and job gates consume.

  Network calls (`git ls-remote`, `gh api`, `curl`) are stubbed by
  prepending a temp dir with fake binaries to `PATH`. The fake
  binaries print canned responses based on their argv so the
  resolver's pure logic (per-platform skip check, modern/legacy
  split, union-by-major, windows_ref mapping) can be exercised
  hermetically.
  """

  use ExUnit.Case, async: true

  Code.require_file("shell_test_helper.exs", __DIR__)
  alias Awfy.Fill.ShellTestHelper

  @script Path.expand("../../bin/resolve-fill-needs.sh", __DIR__)

  # Realistic-ish SHAs so the per-(ref, platform) skip-check grep
  # (`_<sha10>-test-`) has something stable to match against.
  @shas %{
    "OTP-20.3" => "a113f6117fd696ea6f84ed754055b4ec97a7ccb2",
    "OTP-21.3.8.24" => "2735ffc3d883afa727569fa5becba3d32e262ace",
    "OTP-22.3.4.27" => "106609456818d9983c932db2cdbaaad8577b98f9",
    "OTP-23.3.4.20" => "60c60ff27b37b34b79218aef0ceb92f68e54f83f",
    "OTP-26.2.5.20" => "e5d6d95c9aac559b59b78c66eb558ee54bd4e006",
    "OTP-28.5" => "f4506ee46d68694a1d23ca81c314092fd83e8f85"
  }

  setup do
    {:ok, tmp: ShellTestHelper.setup_stub_dir("awfy-resolve-test")}
  end

  describe "modern/legacy partition" do
    test "single modern OTP ref lands in modern_* only", %{tmp: tmp} do
      out = run(tmp, "OTP-28.5")

      assert [%{"ref" => "OTP-28.5", "mode" => "modern"}] = out["targets_modern_linux"]
      assert out["targets_modern_macos"] == out["targets_modern_linux"]
      assert out["targets_modern_windows"] == out["targets_modern_linux"]
      assert out["targets_legacy_linux"] == []
      assert out["targets_legacy_macos"] == []
      assert out["targets_legacy_windows"] == []
      assert out["has_modern_linux"] == "true"
      assert out["has_legacy_linux"] == "false"
      assert out["has_legacy_build"] == "false"
    end

    test "single legacy (< 24) OTP ref lands in legacy_* only", %{tmp: tmp} do
      out = run(tmp, "OTP-21.3.8.24")

      assert [%{"ref" => "OTP-21.3.8.24", "mode" => "legacy"}] = out["targets_legacy_linux"]
      assert out["targets_modern_linux"] == []
      assert out["has_modern_linux"] == "false"
      assert out["has_legacy_linux"] == "true"
      assert out["has_legacy_build"] == "true"
    end

    test "mixed modern + legacy refs are partitioned by major", %{tmp: tmp} do
      out = run(tmp, "OTP-21.3.8.24,OTP-28.5")

      assert [%{"ref" => "OTP-21.3.8.24"}] = out["targets_legacy_linux"]
      assert [%{"ref" => "OTP-28.5"}] = out["targets_modern_linux"]
    end
  end

  describe "windows_ref legacy mapping" do
    test "OTP-21.3.8.24 → windows_ref OTP-21.3 (function-release installer)", %{tmp: tmp} do
      out = run(tmp, "OTP-21.3.8.24")

      assert [%{"windows_ref" => "OTP-21.3", "windows_otp_label" => "21.3"}] =
               out["targets_legacy_windows"]
    end

    test "modern refs pass windows_ref through unchanged", %{tmp: tmp} do
      out = run(tmp, "OTP-28.5")

      assert [%{"windows_ref" => "OTP-28.5", "windows_otp_label" => "28.5"}] =
               out["targets_modern_windows"]
    end
  end

  describe "targets_legacy_build union" do
    test "windows-only legacy work still produces a build entry", %{tmp: tmp} do
      # Pretend OTP-21.3.8.24 already has linux + macos on gh-pages, only
      # windows is missing. The resolver should still emit a legacy_build
      # entry so build-linux-target + prep-target-bundle fire and the
      # downstream measure-windows-target row materialises.
      out =
        run(tmp, "OTP-21.3.8.24",
          fill_mode: "1",
          existing_rundirs: [
            "20260101T0000_otp21_elixir1.11.4_2735ffc3d8-test-linux-x86_64-emu",
            "20260101T0000_otp21_elixir1.11.4_2735ffc3d8-test-macos-arm64-emu"
          ]
        )

      assert out["targets_legacy_linux"] == []
      assert out["targets_legacy_macos"] == []
      assert [%{"ref" => "OTP-21.3.8.24"}] = out["targets_legacy_windows"]
      assert [%{"ref" => "OTP-21.3.8.24", "major" => "21"}] = out["targets_legacy_build"]
      assert out["has_legacy_build"] == "true"
    end

    test "deduplicates by major across the three legacy arrays", %{tmp: tmp} do
      # OTP-21 appears in macos + windows arrays; expect one entry in build.
      out =
        run(tmp, "OTP-21.3.8.24",
          fill_mode: "1",
          existing_rundirs: [
            "20260101T0000_otp21_elixir1.11.4_2735ffc3d8-test-linux-x86_64-emu"
          ]
        )

      assert [%{"major" => "21"}] = out["targets_legacy_build"]
    end

    test "multiple legacy majors each get their own build entry", %{tmp: tmp} do
      out = run(tmp, "OTP-21.3.8.24,OTP-22.3.4.27,OTP-23.3.4.20")

      majors =
        out["targets_legacy_build"]
        |> Enum.map(& &1["major"])
        |> Enum.sort()

      assert majors == ["21", "22", "23"]
      assert out["has_legacy_build"] == "true"
    end

    test "modern-only run leaves legacy_build empty", %{tmp: tmp} do
      out = run(tmp, "OTP-26.2.5.20,OTP-28.5")

      assert out["targets_legacy_build"] == []
      assert out["has_legacy_build"] == "false"
    end
  end

  describe "fill-mode skip check" do
    test "ref with all three platforms on gh-pages is fully skipped", %{tmp: tmp} do
      out =
        run(tmp, "OTP-28.5",
          fill_mode: "1",
          existing_rundirs: [
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit",
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-macos-arm64-jit",
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-windows-x86_64-jit"
          ]
        )

      assert out["targets_modern_linux"] == []
      assert out["targets_modern_macos"] == []
      assert out["targets_modern_windows"] == []
    end

    test "missing one platform → only that platform is in the matrix", %{tmp: tmp} do
      out =
        run(tmp, "OTP-28.5",
          fill_mode: "1",
          existing_rundirs: [
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit",
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-macos-arm64-jit"
          ]
        )

      assert out["targets_modern_linux"] == []
      assert out["targets_modern_macos"] == []
      assert [%{"ref" => "OTP-28.5"}] = out["targets_modern_windows"]
    end

    test "fill_mode off ignores gh-pages contents and runs every platform", %{tmp: tmp} do
      out =
        run(tmp, "OTP-28.5",
          fill_mode: "0",
          existing_rundirs: [
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit",
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-macos-arm64-jit",
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-windows-x86_64-jit"
          ]
        )

      assert [%{}] = out["targets_modern_linux"]
      assert [%{}] = out["targets_modern_macos"]
      assert [%{}] = out["targets_modern_windows"]
    end
  end

  # --- harness -------------------------------------------------------

  defp run(tmp, refs, opts \\ []) do
    fill_mode = Keyword.get(opts, :fill_mode, "0")
    existing_rundirs = Keyword.get(opts, :existing_rundirs, [])

    output_file = Path.join(tmp, "github_output")
    File.write!(output_file, "")

    install_stubs(tmp, existing_rundirs)

    env = [
      {"PATH", "#{tmp}:#{System.get_env("PATH")}"},
      {"GITHUB_OUTPUT", output_file},
      {"GITHUB_REPOSITORY", "test/awfy"},
      {"FILL_MODE", fill_mode},
      {"INPUT_BENCHMARKS", Keyword.get(opts, :input_benchmarks, "")}
    ]

    {log, status} =
      System.cmd("bash", [@script, refs], env: env, stderr_to_stdout: true)

    assert status == 0, "resolver exited #{status}:\n#{log}"

    parse_output(output_file)
  end

  defp parse_output(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)

      # Only the targets_* values are JSON arrays; the has_* booleans
      # are plain "true"/"false" strings, which Jason.decode would
      # turn into Elixir booleans — keep them as strings so the
      # assertions can match the literal GHA output.
      decoded =
        case v do
          "[" <> _ -> Jason.decode!(v)
          "{" <> _ -> Jason.decode!(v)
          _ -> v
        end

      {k, decoded}
    end)
  end

  defp install_stubs(tmp, existing_rundirs) do
    # `git ls-remote` returns "<sha>\t<refname>"; pick our canned SHA
    # based on the ref in argv. Falls back to a zero SHA so an
    # unmapped ref doesn't silently match a real one.
    sha_cases =
      @shas
      |> Enum.map(fn {ref, sha} ->
        "    *#{ref}*) echo -e \"#{sha}\\trefs/tags/#{ref}\" ;;"
      end)
      |> Enum.join("\n")

    git_body = """
    case "$1" in
      ls-remote)
        case "$3" in
    #{sha_cases}
          *) ;;
        esac
        ;;
      remote)
        echo "https://github.com/test/awfy.git"
        ;;
      *) exit 0 ;;
    esac
    """

    # `gh api repos/.../contents?ref=gh-pages` returns one rundir name
    # per line via `--jq '.[].name'`. The fill probe greps these for
    # `_<sha10>-test-` so we just print each entry on its own line.
    # `gh api repos/erlang/otp/commits/<sha>` returns commit metadata;
    # we hand back {} so the timestamp lookup degrades to empty.
    rundirs_str = Enum.join(existing_rundirs, "\n")

    gh_body = """
    args="$*"
    case "$args" in
      *contents?ref=gh-pages*)
        printf '%s\\n' "#{rundirs_str}"
        ;;
      *git/trees/gh-pages*)
        echo '{}'
        ;;
      *commits/*)
        echo '{}'
        ;;
      *)
        echo '{}'
        ;;
    esac
    """

    # curl is only called for non-OTP-* refs in the OTP_VERSION
    # fallback path; tests don't exercise that, but stub it anyway
    # so a stray invocation doesn't escape the sandbox to real network.
    curl_body = "exit 0\n"

    write_stub(tmp, "git", git_body)
    write_stub(tmp, "gh", gh_body)
    write_stub(tmp, "curl", curl_body)
  end

  defp write_stub(dir, name, body), do: ShellTestHelper.write_stub(dir, name, body)
end
