# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.ExpandOtpRefsTest do
  @moduledoc """
  Tests for `bin/expand-otp-refs.sh` — the workflow's first stage,
  which turns the raw `otp_refs` input (`all`, `fill`, or a CSV like
  `21,28,master`) into a flat list of fully-qualified OTP refs the
  resolver can walk.

  `curl`'s call to upstream `otp_versions.table` is stubbed via a
  PATH-injected fake so the per-major shorthand expansion runs
  against a small, deterministic table baked into the test fixture.
  """

  use ExUnit.Case, async: true

  Code.require_file("shell_test_helper.exs", __DIR__)
  alias Awfy.Fill.ShellTestHelper

  @script Path.expand("../../bin/expand-otp-refs.sh", __DIR__)

  # Trimmed otp_versions.table covering the cases we want to exercise.
  # Order matters: the script walks newest-first and picks the active
  # maintenance line as the first X.Y prefix it sees per major. Format
  # matches upstream: `OTP-X.Y[.Z[.W]] : <apps...> # <unchanged> :`.
  @table """
  OTP-28.5 : x-1.0 :
  OTP-28.4.3 : x-1.0 :
  OTP-28.4 : x-1.0 :
  OTP-27.3.4.11 : x-1.0 :
  OTP-27.3.4.10 : x-1.0 :
  OTP-27.3 : x-1.0 :
  OTP-26.2.5.20 : x-1.0 :
  OTP-26.2 : x-1.0 :
  OTP-23.3.4.20 : x-1.0 :
  OTP-23.3 : x-1.0 :
  OTP-22.3.4.27 : x-1.0 :
  OTP-22.3 : x-1.0 :
  OTP-21.3.8.24 : x-1.0 :
  OTP-21.3 : x-1.0 :
  OTP-21.2.7 : x-1.0 :
  OTP-21.2 : x-1.0 :
  OTP-20.3 : x-1.0 :
  """

  setup do
    tmp = ShellTestHelper.setup_stub_dir("awfy-expand-test")
    install_curl_stub(tmp, @table)
    empty_stub = install_empty_merges_stub(tmp)
    {:ok, tmp: tmp, empty_merges_stub: empty_stub}
  end

  describe "all / fill expansion" do
    test "`all` collapses to one tip per major and appends maint,master", %{tmp: tmp} do
      assert run(tmp, "all") ==
               "OTP-20.3,OTP-21.3.8.24,OTP-22.3.4.27,OTP-23.3.4.20,OTP-26.2.5.20,OTP-27.3.4.11,OTP-28.5,maint,master"
    end

    test "`fill` behaves identically to `all` for ref expansion", %{tmp: tmp} do
      assert run(tmp, "fill") == run(tmp, "all")
    end

    test "older function-release lines (OTP-21.2) are skipped", %{tmp: tmp} do
      out = run(tmp, "all")
      refute String.contains?(out, "OTP-21.2")
    end

    test "OTP-20 is pinned to OTP-20.3 (no src-dist for security patches)", %{tmp: tmp} do
      assert String.contains?(run(tmp, "all"), "OTP-20.3")
    end
  end

  describe "master_history expansion" do
    setup %{tmp: tmp} do
      # Stub the enumerate-master-merges helper via env-var override.
      # Write a fake script that emits 3 deterministic SHAs so tests
      # can pin the exact output shape.
      stub = Path.join(tmp, "enumerate-master-merges-stub.sh")

      File.write!(stub, """
      #!/usr/bin/env bash
      echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      echo cccccccccccccccccccccccccccccccccccccccc
      """)

      File.chmod!(stub, 0o755)
      {:ok, stub: stub}
    end

    test "`master_history` emits one master:<sha> ref per merge", %{tmp: tmp, stub: stub} do
      assert run_with_stub(tmp, "master_history", stub) ==
               "master:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa," <>
                 "master:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb," <>
                 "master:cccccccccccccccccccccccccccccccccccccccc"
    end

    test "`fill` appends the same merge list to the maint-tip set", %{tmp: tmp, stub: stub} do
      out = run_with_stub(tmp, "fill", stub)
      assert String.starts_with?(out, "OTP-20.3,")
      assert String.ends_with?(
               out,
               ",master,master:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,master:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,master:cccccccccccccccccccccccccccccccccccccccc"
             )
    end

    test "`all` includes the same merge list", %{tmp: tmp, stub: stub} do
      out = run_with_stub(tmp, "all", stub)
      assert out =~ "master:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end

    test "empty enumeration falls back gracefully", %{tmp: tmp} do
      empty_stub = Path.join(tmp, "empty-stub.sh")
      File.write!(empty_stub, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(empty_stub, 0o755)

      # On master_history with no merges, exit cleanly with a warning
      # rather than emitting an empty refs list that would crash the
      # workflow.
      {log, status} = run_raw_with_stub(tmp, "master_history", empty_stub)
      assert status == 0
      assert log =~ "no refs"
    end
  end

  describe "shorthand expansion" do
    test "two-digit major → newest entry on its active maint line", %{tmp: tmp} do
      assert run(tmp, "21") == "OTP-21.3.8.24"
      assert run(tmp, "22") == "OTP-22.3.4.27"
      assert run(tmp, "28") == "OTP-28.5"
    end

    test "X.Y minor prefix → newest matching patch", %{tmp: tmp} do
      assert run(tmp, "21.3") == "OTP-21.3.8.24"
      assert run(tmp, "26.2") == "OTP-26.2.5.20"
    end

    test "fully-qualified OTP tag passes through verbatim", %{tmp: tmp} do
      assert run(tmp, "OTP-26.2.5.20") == "OTP-26.2.5.20"
    end

    test "branch refs pass through verbatim", %{tmp: tmp} do
      assert run(tmp, "master") == "master"
      assert run(tmp, "maint") == "maint"
      assert run(tmp, "maint-26") == "maint-26"
    end

    test "comma-separated mixed input expands per-token", %{tmp: tmp} do
      assert run(tmp, "21,28,master") == "OTP-21.3.8.24,OTP-28.5,master"
    end

    test "tolerates surrounding whitespace", %{tmp: tmp} do
      assert run(tmp, " 21 , 28 ") == "OTP-21.3.8.24,OTP-28.5"
    end

    test "major with no matching entry exits non-zero with diagnostic", %{tmp: tmp} do
      # `35` matches the 2[0-9]|3[0-9] shorthand pattern but the test
      # table has no OTP-35.x entries; expansion produces an empty
      # string, which the script rejects. (Out-of-pattern tokens like
      # `99` instead pass through verbatim — they're treated as
      # potential branch / SHA refs.)
      {log, status} = run_raw(tmp, "35")
      refute status == 0
      assert log =~ "could not expand shorthand"
    end
  end

  # --- harness -------------------------------------------------------

  defp run(tmp, input) do
    {out, status} = run_raw(tmp, input)
    assert status == 0, "expand-otp-refs exited #{status}:\n#{out}"
    # Script prints expansion to stdout; stderr (diagnostics) is
    # merged but always trails after the last newline-terminated line.
    out
    |> String.split("\n", trim: true)
    |> List.last()
  end

  defp run_raw(tmp, input) do
    env = [
      {"PATH", "#{tmp}:#{System.get_env("PATH")}"},
      # Default to the empty-merges stub so `all`/`fill` paths don't
      # touch network for the master-history enumeration. Tests that
      # want a populated merge list use `run_with_stub/3` below to
      # override.
      {"AWFY_ENUMERATE_MERGES_SH", Path.join(tmp, "enumerate-master-merges-empty.sh")}
    ]

    System.cmd("bash", [@script, input], env: env, stderr_to_stdout: true)
  end

  # Same as `run/2` / `run_raw/2` but injects an AWFY_ENUMERATE_MERGES_SH
  # env var so `master_history_refs()` in expand-otp-refs.sh calls the
  # stub instead of going to network for an erlang/otp clone.
  defp run_with_stub(tmp, input, stub) do
    {out, status} = run_raw_with_stub(tmp, input, stub)
    assert status == 0, "expand-otp-refs exited #{status}:\n#{out}"
    out |> String.split("\n", trim: true) |> List.last()
  end

  defp run_raw_with_stub(tmp, input, stub) do
    env = [
      {"PATH", "#{tmp}:#{System.get_env("PATH")}"},
      {"AWFY_ENUMERATE_MERGES_SH", stub}
    ]

    System.cmd("bash", [@script, input], env: env, stderr_to_stdout: true)
  end

  # Empty enumerate-master-merges stub. Default for the existing
  # `all`/`fill` tests so they keep asserting the maint-tip-only
  # output; tests that need a populated merge list inject their own
  # stub via run_with_stub/3.
  defp install_empty_merges_stub(dir) do
    path = Path.join(dir, "enumerate-master-merges-empty.sh")
    File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp install_curl_stub(dir, table) do
    # The script invokes `curl -fsSL --max-time 15 <url> > $TABLE`,
    # so the stub just needs to print the table on stdout regardless
    # of args. Errors out on any unexpected invocation so a real
    # network call can't slip through.
    body = """
    for arg in "$@"; do
      case "$arg" in
        *otp_versions.table*)
          cat <<'TABLE_EOF'
    #{table}TABLE_EOF
          exit 0
          ;;
      esac
    done
    echo "test curl stub: unexpected args: $*" >&2
    exit 99
    """

    ShellTestHelper.write_stub(dir, "curl", body)
  end
end
