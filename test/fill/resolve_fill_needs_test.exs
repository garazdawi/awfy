# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.ResolveFillNeedsTest do
  @moduledoc """
  Tests for `Awfy.Fill.Resolve` — the resolver that turns a
  comma-separated list of expanded OTP refs into the per-(mode,
  platform) JSON arrays + has_* booleans the bench.yml workflow
  matrices and job gates consume.

  External commands (`git`, `gh`, helper scripts) are stubbed by
  passing a fake shell function via the `:shell` option. The fake
  pattern-matches on argv and returns canned `{output, exit_code}`
  tuples so the resolver's pure logic (per-platform skip check,
  modern/legacy split, union-by-major, windows_ref mapping,
  master:<sha> cap) runs hermetically and in-process.
  """

  use ExUnit.Case, async: true

  alias Awfy.Fill.Resolve

  # Realistic-ish SHAs so the per-(ref, platform) skip-check
  # regex (`_<sha10>-test-`) has something stable to match against.
  @shas %{
    "OTP-20.3" => "a113f6117fd696ea6f84ed754055b4ec97a7ccb2",
    "OTP-21.3.8.24" => "2735ffc3d883afa727569fa5becba3d32e262ace",
    "OTP-22.3.4.27" => "106609456818d9983c932db2cdbaaad8577b98f9",
    "OTP-23.3.4.20" => "60c60ff27b37b34b79218aef0ceb92f68e54f83f",
    "OTP-26.2.5.20" => "e5d6d95c9aac559b59b78c66eb558ee54bd4e006",
    "OTP-28.5" => "f4506ee46d68694a1d23ca81c314092fd83e8f85"
  }

  describe "modern/legacy partition" do
    test "single modern OTP ref lands in modern_* only" do
      out = run("OTP-28.5")

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

    test "single legacy (< 24) OTP ref lands in legacy_* only" do
      out = run("OTP-21.3.8.24")

      assert [%{"ref" => "OTP-21.3.8.24", "mode" => "legacy"}] = out["targets_legacy_linux"]
      assert out["targets_modern_linux"] == []
      assert out["has_modern_linux"] == "false"
      assert out["has_legacy_linux"] == "true"
      assert out["has_legacy_build"] == "true"
    end

    test "mixed modern + legacy refs are partitioned by major" do
      out = run("OTP-21.3.8.24,OTP-28.5")

      assert [%{"ref" => "OTP-21.3.8.24"}] = out["targets_legacy_linux"]
      assert [%{"ref" => "OTP-28.5"}] = out["targets_modern_linux"]
    end
  end

  describe "master:<sha> (master-history) refs" do
    @history_sha String.duplicate("a", 40)

    test "lands in modern_* with otp_label=master + bare SHA windows_ref" do
      out = run("master:#{@history_sha}")

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

    test "every merge gets a distinct short label (one row per merge)" do
      a = String.duplicate("a", 40)
      b = String.duplicate("b", 40)
      out = run("master:#{a},master:#{b}")

      shorts = Enum.map(out["targets_modern_linux"], & &1["short"])
      assert "aaaaaaaaaa" in shorts
      assert "bbbbbbbbbb" in shorts
      assert length(shorts) == 2
    end

    test "all platforms see the same merge (no platform-skipping at resolve time)" do
      out = run("master:#{@history_sha}")
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

    test "drops master:<sha> entries beyond the cap (oldest-first kept)" do
      shas = gen_shas(7)
      out = run(master_refs(shas), max_master_merges: 3)

      kept = Enum.map(out["targets_modern_linux"], & &1["sha"])
      assert length(kept) == 3
      # Oldest-first ordering: first three input refs are the ones
      # that land. Subsequent runs pick up the deferred tail.
      assert kept == Enum.take(shas, 3)
    end

    test "cap counts unique SHAs, not per-platform entries" do
      # Three master SHAs, cap=3, no fill skip → each lands on all
      # three platforms = 9 platform entries total, but only 3 SHAs
      # consumed the cap.
      shas = gen_shas(3)
      out = run(master_refs(shas), max_master_merges: 3)

      assert length(out["targets_modern_linux"]) == 3
      assert length(out["targets_modern_macos"]) == 3
      assert length(out["targets_modern_windows"]) == 3
    end

    test "maint-tip refs aren't subject to the cap" do
      # Five master:<sha> + two OTP tags, cap=2. The two OTP tags
      # should land regardless of how full the master cap is.
      master_shas = gen_shas(5)
      refs = master_refs(master_shas) <> ",OTP-21.3.8.24,OTP-28.5"

      out = run(refs, max_master_merges: 2)

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

    test "already-done master:<sha> don't consume cap slots" do
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
        run(master_refs([done_a, done_b | rest]),
          fill_mode: true,
          canonical_synthetic: "Bounce",
          canonical_xmpp: "",
          max_master_merges: 3,
          existing_rundirs: existing_rundirs,
          existing_benchees: existing_benchees
        )

      kept = Enum.map(out["targets_modern_linux"], & &1["sha"])
      assert kept == rest
    end

    test "MAX_MASTER_MERGES=0 disables the cap" do
      shas = gen_shas(8)
      out = run(master_refs(shas), max_master_merges: 0)
      assert length(out["targets_modern_linux"]) == 8
    end
  end

  describe "canonical benchmark set + per-target missing list" do
    @sha String.duplicate("c", 40)

    test "in fill mode with no existing rundirs, missing = full canonical set" do
      out =
        run("OTP-28.5",
          fill_mode: true,
          canonical_synthetic: "Bounce,CD,phash2",
          canonical_xmpp: ""
        )

      [linux] = out["targets_modern_linux"]
      assert linux["benchmarks"] == "Bounce,CD,phash2"
    end

    test "in fill mode, missing = canonical minus what's already on gh-pages" do
      # Bounce + CD already published for this SHA; phash2 missing.
      # The resolver should emit benchmarks="phash2" so the matrix
      # only re-measures the missing one, not the full set.
      out =
        run("OTP-28.5",
          fill_mode: true,
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

    test "in fill mode, all canonical present → ref skipped entirely" do
      out =
        run("OTP-28.5",
          fill_mode: true,
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

    test "needs_xmpp=true when dynamic_domains_pm missing on linux" do
      out =
        run("master:#{@sha}",
          fill_mode: true,
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

    test "no INPUT_BENCHMARKS + no canonical = legacy 'any rundir = done'" do
      # Backward-compat path: when bench.yml's resolve job doesn't
      # set CANONICAL_SYNTHETIC (local invocations, old workflow
      # paths), fall back to the pre-canonical "any rundir present
      # = skip" check.
      out =
        run("OTP-28.5",
          fill_mode: true,
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
    test "OTP-21.3.8.24 → windows_ref OTP-21.3 (function-release installer)" do
      out = run("OTP-21.3.8.24")

      assert [%{"windows_ref" => "OTP-21.3", "windows_otp_label" => "21.3"}] =
               out["targets_legacy_windows"]
    end

    test "modern refs pass windows_ref through unchanged" do
      out = run("OTP-28.5")

      assert [%{"windows_ref" => "OTP-28.5", "windows_otp_label" => "28.5"}] =
               out["targets_modern_windows"]
    end
  end

  describe "targets_legacy_build union" do
    test "windows-only legacy work still produces a build entry" do
      # Pretend OTP-21.3.8.24 already has linux + macos on gh-pages, only
      # windows is missing. The resolver should still emit a legacy_build
      # entry so build-linux-target + prep-target-bundle fire and the
      # downstream measure-windows-target row materialises.
      out =
        run("OTP-21.3.8.24",
          fill_mode: true,
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

    test "deduplicates by major across the three legacy arrays" do
      # OTP-21 appears in macos + windows arrays; expect one entry in build.
      out =
        run("OTP-21.3.8.24",
          fill_mode: true,
          existing_rundirs: [
            "20260101T0000_otp21_elixir1.11.4_2735ffc3d8-test-linux-x86_64-emu"
          ]
        )

      assert [%{"major" => "21"}] = out["targets_legacy_build"]
    end

    test "multiple legacy majors each get their own build entry" do
      out = run("OTP-21.3.8.24,OTP-22.3.4.27,OTP-23.3.4.20")

      majors =
        out["targets_legacy_build"]
        |> Enum.map(& &1["major"])
        |> Enum.sort()

      assert majors == ["21", "22", "23"]
      assert out["has_legacy_build"] == "true"
    end

    test "modern-only run leaves legacy_build empty" do
      out = run("OTP-26.2.5.20,OTP-28.5")

      assert out["targets_legacy_build"] == []
      assert out["has_legacy_build"] == "false"
    end
  end

  describe "fill-mode skip check" do
    test "ref with all three platforms on gh-pages is fully skipped" do
      out =
        run("OTP-28.5",
          fill_mode: true,
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

    test "missing one platform → only that platform is in the matrix" do
      out =
        run("OTP-28.5",
          fill_mode: true,
          existing_rundirs: [
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-linux-x86_64-jit",
            "20260101_otp28_elixir1.19.5_f4506ee46d-test-macos-arm64-jit"
          ]
        )

      assert out["targets_modern_linux"] == []
      assert out["targets_modern_macos"] == []
      assert [%{"ref" => "OTP-28.5"}] = out["targets_modern_windows"]
    end

    test "fill_mode off ignores gh-pages contents and runs every platform" do
      out =
        run("OTP-28.5",
          fill_mode: false,
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

  describe "skip_platforms" do
    @sha String.duplicate("d", 40)

    test "SHA whose only missing slot is a skipped platform is dropped" do
      # linux + windows already on gh-pages; macos is the only gap.
      # With skip_platforms=[macos] the resolver pretends macos is
      # out of scope → no platform needs work → SHA skipped entirely
      # rather than perpetually flagged across every fill.
      out =
        run("master:#{@sha}",
          fill_mode: true,
          skip_platforms: ["macos"],
          canonical_synthetic: "Bounce",
          canonical_xmpp: "",
          existing_rundirs: [
            "20260101_otp30_elixir1.19.5_dddddddddd-test-linux-x86_64-jit",
            "20260101_otp30_elixir1.19.5_dddddddddd-test-windows-x86_64-jit"
          ],
          existing_benchees: [
            "20260101_otp30_elixir1.19.5_dddddddddd-test-linux-x86_64-jit/Bounce.benchee",
            "20260101_otp30_elixir1.19.5_dddddddddd-test-windows-x86_64-jit/Bounce.benchee"
          ]
        )

      assert out["targets_modern_linux"] == []
      assert out["targets_modern_macos"] == []
      assert out["targets_modern_windows"] == []
    end

    test "skipped platform never appears in the matrix even when other platforms need work" do
      # linux missing, windows + macos already present. Without
      # skip_platforms the resolver would queue linux only. With
      # skip_platforms=[macos] the matrix still only has linux —
      # confirms the skip applies to OUTPUT (no macos entry) not
      # just to the gap math.
      out =
        run("master:#{@sha}",
          fill_mode: true,
          skip_platforms: ["macos"],
          canonical_synthetic: "Bounce",
          canonical_xmpp: "",
          existing_rundirs: [
            "20260101_otp30_elixir1.19.5_dddddddddd-test-windows-x86_64-jit"
          ],
          existing_benchees: [
            "20260101_otp30_elixir1.19.5_dddddddddd-test-windows-x86_64-jit/Bounce.benchee"
          ]
        )

      assert [%{"benchmarks" => "Bounce"}] = out["targets_modern_linux"]
      assert out["targets_modern_macos"] == []
    end
  end

  # --- harness -------------------------------------------------------

  # Call the resolver in-process with a fake shell. We decode the
  # JSON values it returns so test assertions see Elixir
  # lists/maps rather than the strings the GHA output file would
  # contain.
  defp run(refs, opts \\ []) do
    existing_rundirs = Keyword.get(opts, :existing_rundirs, [])
    existing_benchees = Keyword.get(opts, :existing_benchees, [])

    resolver_opts = [
      fill_mode: Keyword.get(opts, :fill_mode, false),
      input_benchmarks: Keyword.get(opts, :input_benchmarks, ""),
      canonical_synthetic: Keyword.get(opts, :canonical_synthetic, ""),
      canonical_xmpp: Keyword.get(opts, :canonical_xmpp, ""),
      max_master_merges: Keyword.get(opts, :max_master_merges, 50),
      skip_platforms: Keyword.get(opts, :skip_platforms, []),
      github_repository: "test/awfy",
      shell: fake_shell(existing_rundirs, existing_benchees)
    ]

    refs
    |> Resolve.resolve(resolver_opts)
    |> decode_outputs()
  end

  # The resolver emits targets_* as Jason-encoded strings (so the
  # CLI wrapper can write them verbatim to $GITHUB_OUTPUT). Decode
  # back to Elixir terms here so test bodies pattern-match on lists
  # and maps. has_* booleans stay as the literal "true"/"false"
  # strings, mirroring what bench.yml's matrix gates compare
  # against.
  defp decode_outputs(map) do
    Map.new(map, fn
      {"targets_" <> _ = k, v} -> {k, Jason.decode!(v)}
      {k, v} -> {k, v}
    end)
  end

  # The fake shell dispatches on the basename of the command and
  # an argv "shape" (the first argv element identifies the API
  # surface). Argv coverage mirrors what `Awfy.Fill.Resolve`
  # actually calls; an unhandled call falls through to flunk/1 so
  # new resolver shell-outs surface as test failures rather than
  # silent empty strings.
  defp fake_shell(existing_rundirs, existing_benchees) do
    fn cmd, args ->
      dispatch(Path.basename(cmd), args, existing_rundirs, existing_benchees)
    end
  end

  defp dispatch("git", ["ls-remote", _url, ref], _rundirs, _benchees) do
    # Trim a trailing ^{} (annotated-tag dereference) so the lookup
    # table is keyed by the canonical ref name.
    base = String.replace_suffix(ref, "^{}", "")

    case Map.fetch(@shas, base) do
      {:ok, sha} -> {"#{sha}\trefs/tags/#{base}\n", 0}
      :error -> {"", 0}
    end
  end

  defp dispatch("gh", ["api" | rest], rundirs, benchees) do
    gh_api(rest, rundirs, benchees)
  end

  defp dispatch("curl", args, _rundirs, _benchees) do
    if Enum.any?(args, &String.contains?(&1, "OTP_VERSION")) do
      {"30.0\n", 0}
    else
      {"", 0}
    end
  end

  defp dispatch("next-master-major.sh", _args, _rundirs, _benchees), do: {"30\n", 0}

  defp dispatch("elixir-for-otp.sh", [major], _rundirs, _benchees) do
    # Mirror priv/elixir-for-otp.sh's table; only the rows the
    # tests exercise are needed. Default lines up with the script's
    # catch-all (latest Elixir).
    out =
      case major do
        "20" -> "1.9.4\n"
        "21" -> "1.11.4\n"
        "22" -> "1.13.4\n"
        "23" -> "1.14.5\n"
        "24" -> "1.16.3\n"
        "25" -> "1.17.3\n"
        "26" -> "1.18.4\n"
        "27" -> "1.19.5\n"
        _ -> "1.19.5\n"
      end

    {out, 0}
  end

  defp dispatch(prog, args, _rundirs, _benchees) do
    flunk("fake shell: unhandled call #{prog} #{Enum.join(args, " ")}")
  end

  # `gh api <url> [flags]`. We dispatch on the URL fragment that
  # tells us which endpoint the resolver is hitting.
  defp gh_api([url | _flags], rundirs, benchees) when is_binary(url) do
    cond do
      String.contains?(url, "contents?ref=gh-pages") ->
        {Enum.join(rundirs, "\n") <> "\n", 0}

      String.contains?(url, "git/trees/gh-pages") ->
        {gh_tree_json(benchees), 0}

      String.contains?(url, "commits/") ->
        # The resolver's call uses `--jq '.commit.committer.date // ""'`
        # so an empty line is the documented "no date" sentinel.
        {"\n", 0}

      true ->
        {"", 0}
    end
  end

  defp gh_tree_json(paths) do
    Jason.encode!(%{
      "tree" => Enum.map(paths, fn path -> %{"path" => path, "type" => "blob"} end),
      "truncated" => false
    })
  end
end
