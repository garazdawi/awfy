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
      # Per-platform entries differ only in linux-specific fields
      # (`needs_xmpp`, `skip_synthetic`); the shared ref/sha/label
      # fields match across platforms.
      [linux] = out["targets_modern_linux"]
      [macos] = out["targets_modern_macos"]
      [windows] = out["targets_modern_windows"]
      assert linux["sha"] == macos["sha"]
      assert linux["sha"] == windows["sha"]
      assert linux["label"] == macos["label"]
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

  describe "master:<sha> (master-history) refs" do
    @history_sha String.duplicate("a", 40)

    test "lands in modern_* with otp_label=master + bare SHA windows_ref", %{tmp: tmp} do
      out = run(tmp, "master:#{@history_sha}")

      [linux] = out["targets_modern_linux"]
      assert linux["ref"] == "master:#{@history_sha}"
      assert linux["sha"] == @history_sha
      assert linux["short"] == String.slice(@history_sha, 0..9)
      assert linux["otp_label"] == "master"
      assert linux["mode"] == "modern"
      # Windows must use the bare SHA so install-otp-windows.ps1's
      # `head_sha=<sha>` query against erlang/otp's GHA runs matches.
      # The install step soft-skips per-SHA when no installer artifact
      # is found (commits that touch no C code don't recut one) —
      # the matrix row is always queued, runtime decides.
      [windows] = out["targets_modern_windows"]
      assert windows["windows_ref"] == @history_sha
      assert windows["windows_otp_label"] == "master"
    end

    test "every merge gets a distinct short label (one row per merge)", %{tmp: tmp} do
      a = String.duplicate("a", 40)
      b = String.duplicate("b", 40)
      out = run(tmp, "master:#{a},master:#{b}")

      shorts = Enum.map(out["targets_modern_linux"], & &1["short"])
      assert "aaaaaaaaaa" in shorts
      assert "bbbbbbbbbb" in shorts
      assert length(shorts) == 2
    end

    test "all platforms see the same merge (no platform-skipping at resolve time)", %{tmp: tmp} do
      out = run(tmp, "master:#{@history_sha}")
      assert length(out["targets_modern_linux"]) == 1
      assert length(out["targets_modern_macos"]) == 1
      assert length(out["targets_modern_windows"]) == 1
    end
  end

  describe "MAX_MASTER_MERGES cap" do
    # Generate N distinct 40-char SHAs whose first-10 prefixes are
    # also distinct (the gh-pages skip check matches on the 10-char
    # short SHA). Bake the index into the prefix so test SHAs sort
    # lexicographically the same way enumerate-master-merges.sh emits
    # them (oldest first).
    defp gen_shas(n) do
      Enum.map(1..n, fn i ->
        prefix = i |> Integer.to_string(16) |> String.pad_leading(10, "a")
        prefix <> String.duplicate("b", 30)
      end)
    end

    defp master_refs(shas), do: Enum.map_join(shas, ",", &"master:#{&1}")

    test "drops master:<sha> entries beyond the cap (oldest-first kept)", %{tmp: tmp} do
      shas = gen_shas(7)
      out = run(tmp, master_refs(shas), max_master_merges: 3)

      kept = Enum.map(out["targets_modern_linux"], & &1["sha"])
      assert length(kept) == 3
      # Oldest-first ordering: first three input refs are the ones
      # that land. Subsequent runs pick up the deferred tail.
      assert kept == Enum.take(shas, 3)
    end

    test "cap counts unique SHAs, not per-platform entries", %{tmp: tmp} do
      # Three master SHAs, cap=3, no fill skip → each lands on all
      # three platforms = 9 platform entries total, but only 3 SHAs
      # consumed the cap.
      shas = gen_shas(3)
      out = run(tmp, master_refs(shas), max_master_merges: 3)

      assert length(out["targets_modern_linux"]) == 3
      assert length(out["targets_modern_macos"]) == 3
      assert length(out["targets_modern_windows"]) == 3
    end

    test "maint-tip refs aren't subject to the cap", %{tmp: tmp} do
      # Five master:<sha> + two OTP tags, cap=2. The two OTP tags
      # should land regardless of how full the master cap is.
      master_shas = gen_shas(5)
      refs = master_refs(master_shas) <> ",OTP-21.3.8.24,OTP-28.5"

      out = run(tmp, refs, max_master_merges: 2)

      assert length(out["targets_modern_linux"]) == 2 + 1
      # Both OTP-* refs land in their respective mode arrays.
      assert [%{"ref" => "OTP-21.3.8.24"}] = out["targets_legacy_linux"]
      modern_refs = Enum.map(out["targets_modern_linux"], & &1["ref"])
      assert "OTP-28.5" in modern_refs
      # And exactly two master:<sha> refs are kept (the first two).
      kept_master =
        out["targets_modern_linux"]
        |> Enum.filter(fn t -> String.starts_with?(t["ref"], "master:") end)
        |> Enum.map(& &1["sha"])

      assert kept_master == Enum.take(master_shas, 2)
    end

    test "already-done master:<sha> don't consume cap slots", %{tmp: tmp} do
      # Five master SHAs; the first two are already complete on
      # gh-pages. Cap=3. We expect the three later ones (which still
      # need work) to land — the cap restricts new work, not total
      # candidates seen.
      [done_a, done_b | rest] = gen_shas(5)
      done_shorts = [String.slice(done_a, 0..9), String.slice(done_b, 0..9)]

      existing_rundirs =
        for short <- done_shorts,
            plat <- ["linux", "macos", "windows"] do
          "20260101_otp30_elixir1.19.5_#{short}-test-#{plat}-x86_64-jit"
        end

      existing_benchees =
        for short <- done_shorts,
            plat <- ["linux", "macos", "windows"] do
          "20260101_otp30_elixir1.19.5_#{short}-test-#{plat}-x86_64-jit/Bounce.benchee"
        end

      out =
        run(tmp, master_refs([done_a, done_b | rest]),
          fill_mode: "1",
          canonical_synthetic: "Bounce",
          canonical_xmpp: "",
          max_master_merges: 3,
          existing_rundirs: existing_rundirs,
          existing_benchees: existing_benchees
        )

      kept = Enum.map(out["targets_modern_linux"], & &1["sha"])
      assert kept == rest
    end

    test "MAX_MASTER_MERGES=0 disables the cap", %{tmp: tmp} do
      shas = gen_shas(8)
      out = run(tmp, master_refs(shas), max_master_merges: 0)
      assert length(out["targets_modern_linux"]) == 8
    end
  end

  describe "canonical benchmark set + per-target missing list" do
    @sha String.duplicate("c", 40)

    test "in fill mode with no existing rundirs, missing = full canonical set", %{tmp: tmp} do
      out = run(tmp, "OTP-28.5",
        fill_mode: "1",
        canonical_synthetic: "Bounce,CD,phash2",
        canonical_xmpp: ""
      )

      [linux] = out["targets_modern_linux"]
      assert linux["benchmarks"] == "Bounce,CD,phash2"
    end

    test "in fill mode, missing = canonical minus what's already on gh-pages", %{tmp: tmp} do
      # Bounce + CD already published for this SHA; phash2 missing.
      # The resolver should emit benchmarks="phash2" so the matrix
      # only re-measures the missing one, not the full set.
      out = run(tmp, "OTP-28.5",
        fill_mode: "1",
        canonical_synthetic: "Bounce,CD,phash2",
        canonical_xmpp: "",
        existing_rundirs: [
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit"
        ],
        existing_benchees: [
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit/Bounce.benchee",
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit/CD.benchee"
        ]
      )

      [linux] = out["targets_modern_linux"]
      assert linux["benchmarks"] == "phash2"
    end

    test "in fill mode, all canonical present → ref skipped entirely", %{tmp: tmp} do
      out = run(tmp, "OTP-28.5",
        fill_mode: "1",
        canonical_synthetic: "Bounce",
        canonical_xmpp: "",
        existing_rundirs: [
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit"
        ],
        existing_benchees:
          for plat <- ["linux", "macos", "windows"] do
            "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-#{plat}-x86_64-jit/Bounce.benchee"
          end
      )

      assert out["targets_modern_linux"] == []
      assert out["targets_modern_macos"] == []
      assert out["targets_modern_windows"] == []
    end

    test "needs_xmpp=true when dynamic_domains_pm missing on linux", %{tmp: tmp} do
      out = run(tmp, "master:#{@sha}",
        fill_mode: "1",
        canonical_synthetic: "Bounce",
        canonical_xmpp: "dynamic_domains_pm",
        existing_rundirs: [
          "20260101T0000_otp30_elixir1.19.5_cccccccccc-test-linux-x86_64-jit"
        ],
        existing_benchees: [
          # Bounce present on linux, but no dynamic_domains_pm anywhere
          "20260101T0000_otp30_elixir1.19.5_cccccccccc-test-linux-x86_64-jit/Bounce.benchee",
          "20260101T0000_otp30_elixir1.19.5_cccccccccc-test-linux-arm64-jit/Bounce.benchee",
          "20260101T0000_otp30_elixir1.19.5_cccccccccc-test-macos-arm64-jit/Bounce.benchee"
        ]
      )

      [linux] = out["targets_modern_linux"]
      # Synthetic complete → no synthetic re-run, but XMPP missing.
      assert linux["benchmarks"] == ""
      assert linux["needs_xmpp"] == true
      # skip_synthetic flips on so measure-linux doesn't re-measure
      # the already-complete synthetic suite.
      assert linux["skip_synthetic"] == true
    end

    test "no INPUT_BENCHMARKS + no canonical = legacy 'any rundir = done'", %{tmp: tmp} do
      # Backward-compat path: when bench.yml's resolve job doesn't
      # set CANONICAL_SYNTHETIC (local invocations, old workflow
      # paths), fall back to the pre-canonical "any rundir present
      # = skip" check.
      out = run(tmp, "OTP-28.5",
        fill_mode: "1",
        canonical_synthetic: "",
        canonical_xmpp: "",
        existing_rundirs: [
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit",
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-macos-arm64-jit",
          "20260101T0000_otp28_elixir1.19.5_f4506ee46d-test-windows-x86_64-jit"
        ]
      )

      assert out["targets_modern_linux"] == []
      assert out["targets_modern_macos"] == []
      assert out["targets_modern_windows"] == []
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
    existing_benchees = Keyword.get(opts, :existing_benchees, [])
    canonical_synthetic = Keyword.get(opts, :canonical_synthetic, "")
    canonical_xmpp = Keyword.get(opts, :canonical_xmpp, "")

    output_file = Path.join(tmp, "github_output")
    File.write!(output_file, "")

    install_stubs(tmp, existing_rundirs, existing_benchees)

    env = [
      {"PATH", "#{tmp}:#{System.get_env("PATH")}"},
      {"GITHUB_OUTPUT", output_file},
      {"GITHUB_REPOSITORY", "test/awfy"},
      {"FILL_MODE", fill_mode},
      {"INPUT_BENCHMARKS", Keyword.get(opts, :input_benchmarks, "")},
      {"CANONICAL_SYNTHETIC", canonical_synthetic},
      {"CANONICAL_XMPP", canonical_xmpp},
      {"MAX_MASTER_MERGES",
       opts |> Keyword.get(:max_master_merges, 50) |> to_string()}
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

  defp install_stubs(tmp, existing_rundirs, existing_benchees) do
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
    # `gh api ... git/trees/gh-pages?recursive=1` returns a list of
    # benchmark file paths (.benchee blobs) — newer per-benchmark
    # skip check reads this to compute the missing set.
    rundirs_str = Enum.join(existing_rundirs, "\n")

    # `git/trees/gh-pages?recursive=1` returns a JSON tree object;
    # the real script does `jq -r '.tree[]? | select(.type=="blob") | .path'`
    # to extract benchee paths, so the stub has to emit valid JSON.
    tree_json =
      Jason.encode!(%{
        "tree" =>
          Enum.map(existing_benchees, fn path -> %{"path" => path, "type" => "blob"} end),
        "truncated" => false
      })

    gh_body = """
    args="$*"
    case "$args" in
      *contents?ref=gh-pages*)
        printf '%s\\n' "#{rundirs_str}"
        ;;
      *git/trees/gh-pages*)
        cat <<'GH_TREE_JSON_EOF'
    #{tree_json}
    GH_TREE_JSON_EOF
        ;;
      *commits/*)
        echo '{}'
        ;;
      *)
        echo '{}'
        ;;
    esac
    """

    # curl gets called by next-master-major.sh (which probes
    # erlang/otp's master OTP_VERSION when resolving master / maint /
    # master:<sha> refs) and by the non-OTP-* fallback in
    # otp_major_for_ref. Print a deterministic OTP_VERSION for any
    # OTP_VERSION-looking URL, exit 0 otherwise so stray
    # invocations don't escape the sandbox.
    curl_body = """
    for arg in "$@"; do
      case "$arg" in
        *OTP_VERSION*)
          echo "30.0"
          exit 0
          ;;
      esac
    done
    exit 0
    """

    write_stub(tmp, "git", git_body)
    write_stub(tmp, "gh", gh_body)
    write_stub(tmp, "curl", curl_body)
  end

  defp write_stub(dir, name, body), do: ShellTestHelper.write_stub(dir, name, body)
end
