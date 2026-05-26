# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.Resolve do
  @moduledoc """
  Walk a comma-separated list of expanded OTP refs, probe gh-pages
  for what's already published, and emit three per-platform JSON
  arrays of resolved target entries plus the matching `has_*` and
  `targets_legacy_build` outputs the bench.yml matrices consume.

  Replaces `bin/resolve-fill-needs.sh`. See `Mix.Tasks.Awfy.Resolve`
  for the CLI surface bench.yml's resolve step calls.

  ## Outputs

  `resolve/2` returns a map keyed by the GHA output names — same
  contract the bash script wrote to `$GITHUB_OUTPUT`:

      targets_modern_linux=[…]     # one entry per (sha, linux) that needs the modern leg
      targets_modern_macos=[…]
      targets_modern_windows=[…]
      targets_legacy_linux=[…]     # same for OTP < 24
      targets_legacy_macos=[…]
      targets_legacy_windows=[…]
      targets_legacy_build=[…]     # union-by-major of the three legacy_* arrays
      has_modern_linux=true|false  # boolean string per (mode, platform) +
      …                              `has_legacy_build`

  Each target entry is a JSON map with `ref`, `windows_ref`, `sha`,
  `short`, `label`, `major`, `otp_label`, `windows_otp_label`,
  `elixir`, `elixir_bundle`, `commit_timestamp`, `extra_configure`,
  and `mode`. Linux entries additionally carry `benchmarks`,
  `needs_xmpp`, and `skip_synthetic`; macos / windows carry
  `benchmarks` only.

  ## Per-(ref, platform) skip rule

    * `fill_mode: false` → every platform needs to run for every ref.
    * `fill_mode: true`, no canonical set → for each platform, the
      ref needs that platform's run iff there's no
      `_<sha10>-test-<plat>-` run-dir on gh-pages.
    * `fill_mode: true`, canonical set present → for each platform,
      the ref needs that platform's run iff any canonical benchmark
      lacks a matching `<Bench>.benchee` blob under that platform's
      run-dirs. `target.benchmarks` carries the missing subset so
      `mix awfy.measure --benchmarks <missing>` re-measures only the
      gap.

  ## master:<sha> handling

  Refs of the form `master:<sha>` are master-history merges; each
  becomes one entry with `otp_label = "master"`. After the gh-pages
  skip check, the number of `master:<sha>` refs kept per run is
  capped at `:max_master_merges` (default 50). Subsequent fills
  pick up the deferred tail oldest-first. Maint-tip refs aren't
  affected.

  ## Shell injection

  External commands (`git`, `gh`, helper scripts) go through the
  pluggable `:shell` option, which defaults to `System.cmd/3` with
  `stderr_to_stdout: true`. Tests pass an in-process fake that
  pattern-matches on argv so the resolver runs without spawning
  real subprocesses.
  """

  @default_max_master_merges 50
  @otp_git_url "https://github.com/erlang/otp.git"

  @typedoc "`{output, exit_code}` — same shape as `System.cmd/3`."
  @type shell_result :: {String.t(), non_neg_integer()}

  @typedoc "Pluggable command runner. Receives the program name + args."
  @type shell :: (String.t(), [String.t()] -> shell_result)

  @doc """
  Resolve the given CSV of expanded refs into GHA output values.

  Returns a map whose keys match the bash script's `$GITHUB_OUTPUT`
  emissions; targets_* values are JSON-encoded strings (so the
  caller can write them verbatim), has_* values are the literal
  strings `"true"` / `"false"`.

  See module docstring for the full option list.
  """
  @spec resolve(String.t(), keyword()) :: %{required(String.t()) => String.t()}
  def resolve(refs_csv, opts \\ []) when is_binary(refs_csv) do
    state = init_state(opts)

    state =
      refs_csv
      |> parse_refs_csv()
      |> Enum.reduce(state, &process_ref/2)

    emit_diagnostics(state)
    finalize(state)
  end

  # --- state -----------------------------------------------------

  defp init_state(opts) do
    shell = Keyword.get(opts, :shell, &default_shell/2)
    fill_mode = Keyword.get(opts, :fill_mode, false)

    repo =
      Keyword.get(opts, :github_repository) ||
        System.get_env("GITHUB_REPOSITORY") ||
        infer_repo_from_origin(shell)

    state = %{
      shell: shell,
      fill_mode: fill_mode,
      input_benchmarks: Keyword.get(opts, :input_benchmarks, ""),
      canonical_synthetic: Keyword.get(opts, :canonical_synthetic, ""),
      canonical_xmpp: Keyword.get(opts, :canonical_xmpp, ""),
      max_master_merges:
        Keyword.get(opts, :max_master_merges, @default_max_master_merges),
      # Platforms the caller knows the workflow can't actually
      # measure on this run (e.g. measure-macos is `if: false` in
      # bench.yml while the operator drives macOS locally on M5).
      # The resolver pretends those platforms are out of scope:
      # no entries queued, the per-(sha, platform) skip check
      # ignores them so a SHA whose only missing slot is macos
      # gets skipped entirely instead of perpetually flagged.
      skip_platforms:
        opts
        |> Keyword.get(:skip_platforms, [])
        |> Enum.map(&to_string/1)
        |> MapSet.new(),
      github_repository: repo,
      script_dir: Keyword.get(opts, :script_dir, default_script_dir()),
      # Probe results (lazy: only populated in fill_mode).
      existing_rundirs: [],
      existing_benchees: [],
      # Master major lookup is memoised; many refs may need it.
      master_major: nil,
      # Per-platform collectors. Modern + legacy share a list and get
      # partitioned by mode at the end via `Enum.split_with`.
      linux_entries: [],
      macos_entries: [],
      windows_entries: [],
      # master:<sha> cap accounting (master-history refs only).
      n_master_kept: 0,
      n_master_dropped: 0
    }

    if fill_mode do
      populate_existing(state)
    else
      state
    end
  end

  defp default_script_dir do
    Path.expand("../../..", __DIR__)
  end

  defp parse_refs_csv(csv) do
    csv
    |> String.split(",", trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # In fill mode, fetch the gh-pages run-dir + .benchee inventory
  # once so every ref's skip check is local-grep cheap. See the
  # bash script's comments for why we eat one network round-trip
  # up front rather than per-ref.
  defp populate_existing(state) do
    rundirs = gh_pages_rundirs(state)

    benchees =
      if state.input_benchmarks != "" or state.canonical_synthetic != "" or
           state.canonical_xmpp != "" do
        gh_pages_benchees(state)
      else
        []
      end

    diag("[fill] gh-pages has #{length(rundirs)} existing run-dirs")

    if benchees != [] do
      diag("[fill] gh-pages has #{length(benchees)} .benchee blobs")
    end

    %{state | existing_rundirs: rundirs, existing_benchees: benchees}
  end

  # --- per-ref processing ----------------------------------------

  defp process_ref(ref, state) do
    sha = resolve_sha(ref, state)

    if sha == "" do
      raise "could not resolve ref '#{ref}' on erlang/otp"
    end

    short = String.slice(sha, 0, 10)
    label = "#{short}-test"
    {major, state} = otp_major(ref, sha, state)

    canonical_synth =
      if state.input_benchmarks != "",
        do: state.input_benchmarks,
        else: state.canonical_synthetic

    xmpp_applies = xmpp_applies?(state.canonical_xmpp, major)

    {plat_needs, state} =
      compute_plat_needs(
        state,
        short,
        canonical_synth,
        state.canonical_xmpp,
        xmpp_applies
      )

    if state.fill_mode and skip_ref?(plat_needs) do
      diag("[fill] #{ref} (#{short}) already complete on gh-pages — skipping")
      state
    else
      if state.fill_mode do
        log_needs(ref, short, plat_needs)
      end

      case enforce_master_cap(ref, state) do
        {:drop, state} ->
          state

        {:keep, state} ->
          build_and_append(ref, sha, short, label, major, plat_needs, state)
      end
    end
  end

  defp resolve_sha("master:" <> sha, _state), do: sha

  defp resolve_sha(ref, state) do
    # Annotated tags (OTP releases) need `^{}` to dereference the
    # tag object to the commit. Lightweight tags / branches return
    # empty for `^{}`, so fall back to the bare ref.
    case ls_remote(state, "#{ref}^{}") do
      "" -> ls_remote(state, ref)
      sha -> sha
    end
  end

  defp otp_major("master", _sha, state), do: master_major(state)
  defp otp_major("master:" <> _suffix, _sha, state), do: master_major(state)
  defp otp_major("maint", _sha, state), do: master_major(state)

  defp otp_major("maint-" <> rest, _sha, state) do
    {String.split(rest, ".") |> List.first(), state}
  end

  defp otp_major("OTP-" <> rest, _sha, state) do
    {String.split(rest, ".") |> List.first(), state}
  end

  defp otp_major(_ref, sha, state) do
    # Fall back to fetching OTP_VERSION from the resolved SHA. If
    # the curl fails (network blip mid-run), use master's major as
    # a last resort rather than crashing the whole resolve step.
    case fetch_otp_version_major(state, sha) do
      "" -> master_major(state)
      m -> {m, state}
    end
  end

  defp master_major(%{master_major: m} = state) when is_binary(m), do: {m, state}

  defp master_major(state) do
    script = Path.join([state.script_dir, "bin", "next-master-major.sh"])

    case state.shell.(script, []) do
      {out, 0} ->
        m = out |> String.trim() |> String.split("\n") |> List.first()
        {m, %{state | master_major: m}}

      {out, code} ->
        raise "next-master-major.sh failed (exit #{code}):\n#{out}"
    end
  end

  # --- per-(ref, platform) gap math ------------------------------

  defp compute_plat_needs(state, _short, _canon_synth, _canon_xmpp, _xmpp_applies)
       when state.fill_mode == false do
    needs = %{
      need_linux: not skip?(state, "linux"),
      need_macos: not skip?(state, "macos"),
      need_windows: not skip?(state, "windows"),
      needs_xmpp: false,
      benchmarks_linux: "",
      benchmarks_macos: "",
      benchmarks_windows: ""
    }

    {needs, state}
  end

  defp compute_plat_needs(state, short, canon_synth, canon_xmpp, xmpp_applies) do
    {benchmarks_linux, need_linux} =
      plat_gap(state, short, "linux", canon_synth)

    {benchmarks_macos, need_macos} =
      plat_gap(state, short, "macos", canon_synth)

    {benchmarks_windows, need_windows} =
      plat_gap(state, short, "windows", canon_synth)

    needs_xmpp =
      xmpp_applies and state.existing_benchees != [] and
        xmpp_missing?(state.existing_benchees, short, canon_xmpp)

    needs = %{
      need_linux: need_linux,
      need_macos: need_macos,
      need_windows: need_windows,
      needs_xmpp: needs_xmpp,
      benchmarks_linux: benchmarks_linux,
      benchmarks_macos: benchmarks_macos,
      benchmarks_windows: benchmarks_windows
    }

    {needs, state}
  end

  # Wraps missing_for_platform/4 with the skip-platforms shortcut:
  # a skipped platform reports "" missing + need=false so a SHA whose
  # only gap is that platform falls into skip_ref?/1's all-false
  # branch and gets dropped from the matrix entirely.
  defp plat_gap(state, short, plat, canon_synth) do
    if skip?(state, plat) do
      {"", false}
    else
      missing_for_platform(state, short, plat, canon_synth)
    end
  end

  defp skip?(state, plat), do: MapSet.member?(state.skip_platforms, plat)

  # Returns `{benchmarks_csv, needs_run?}`. When canonical_synth is
  # set, the csv lists names that have no matching `.benchee` blob
  # for this (sha, platform). When unset, we fall back to the
  # legacy "any rundir present = done" check and the csv is "" for
  # both run/no-run cases (the workflow's empty-list-skip-step gate
  # handles it from there).
  defp missing_for_platform(state, short, plat, "") do
    rundir_present? = rundir_for?(state.existing_rundirs, short, plat)
    {"", not rundir_present?}
  end

  defp missing_for_platform(state, short, plat, canon_synth) do
    canon = csv_to_list(canon_synth)

    missing =
      Enum.reject(canon, fn b ->
        benchee_present?(state.existing_benchees, short, plat, b)
      end)

    {Enum.join(missing, ","), missing != []}
  end

  defp rundir_for?(rundirs, short, plat) do
    needle = "_#{short}-test-#{plat}-"
    Enum.any?(rundirs, &String.contains?(&1, needle))
  end

  defp benchee_present?(benchees, short, plat, bench) do
    pattern = Regex.compile!("_#{Regex.escape(short)}-test-#{plat}-[^/]+/#{Regex.escape(bench)}\\.benchee$")
    Enum.any?(benchees, &Regex.match?(pattern, &1))
  end

  # XMPP is linux-only and OTP-27+. Mirror the workflow gate so the
  # skip detection matches what would actually run.
  defp xmpp_applies?("", _major), do: false
  defp xmpp_applies?(_canonical, major) when is_binary(major) do
    case Integer.parse(major) do
      {n, ""} -> n >= 27
      _ -> false
    end
  end

  defp xmpp_missing?(benchees, short, canonical_xmpp) do
    canonical_xmpp
    |> csv_to_list()
    |> Enum.any?(fn xb ->
      pattern = Regex.compile!("_#{Regex.escape(short)}-test-linux-[^/]+/#{Regex.escape(xb)}\\.benchee$")
      not Enum.any?(benchees, &Regex.match?(pattern, &1))
    end)
  end

  defp skip_ref?(%{
         need_linux: false,
         need_macos: false,
         need_windows: false,
         needs_xmpp: false
       }),
       do: true

  defp skip_ref?(_), do: false

  defp log_needs(ref, short, n) do
    parts =
      [
        n.need_linux && "linux(#{n.benchmarks_linux})",
        n.need_macos && "macos(#{n.benchmarks_macos})",
        n.need_windows && "windows(#{n.benchmarks_windows})",
        n.needs_xmpp && "xmpp"
      ]
      |> Enum.filter(&is_binary/1)

    diag("[fill] #{ref} (#{short}) needs: " <> Enum.join(parts, " "))
  end

  # --- master:<sha> cap ------------------------------------------

  defp enforce_master_cap("master:" <> _, %{max_master_merges: 0} = state),
    do: {:keep, state}

  defp enforce_master_cap("master:" <> _, state)
       when state.n_master_kept >= state.max_master_merges do
    {:drop, %{state | n_master_dropped: state.n_master_dropped + 1}}
  end

  defp enforce_master_cap("master:" <> _, state) do
    {:keep, %{state | n_master_kept: state.n_master_kept + 1}}
  end

  defp enforce_master_cap(_other, state), do: {:keep, state}

  # --- entry construction ----------------------------------------

  defp build_and_append(ref, sha, short, label, major, plat_needs, state) do
    elixir = elixir_for_major(state, major)
    elixir_bundle = elixir_bundle_major(major)
    commit_timestamp = commit_timestamp(state, sha)
    {mode, extra_configure} = mode_for_major(major)
    otp_label = otp_label_for(ref, major)
    {windows_ref, windows_otp_label} = windows_mapping(ref, sha, mode, otp_label)

    base = %{
      "ref" => ref,
      "windows_ref" => windows_ref,
      "sha" => sha,
      "short" => short,
      "label" => label,
      "major" => major,
      "otp_label" => otp_label,
      "windows_otp_label" => windows_otp_label,
      "elixir" => elixir,
      "elixir_bundle" => elixir_bundle,
      "commit_timestamp" => commit_timestamp,
      "extra_configure" => extra_configure,
      "mode" => mode
    }

    linux_entry =
      Map.merge(base, %{
        "benchmarks" => plat_needs.benchmarks_linux,
        "needs_xmpp" => plat_needs.needs_xmpp,
        # skip_synthetic flips on for linux refs queued only for
        # XMPP (synthetic complete, xmpp missing) so measure-linux
        # doesn't re-measure the synthetic suite this row.
        "skip_synthetic" =>
          not plat_needs.need_linux and plat_needs.needs_xmpp
      })

    macos_entry = Map.put(base, "benchmarks", plat_needs.benchmarks_macos)
    windows_entry = Map.put(base, "benchmarks", plat_needs.benchmarks_windows)

    state =
      if plat_needs.need_linux or plat_needs.needs_xmpp do
        %{state | linux_entries: [linux_entry | state.linux_entries]}
      else
        state
      end

    state =
      if plat_needs.need_macos do
        %{state | macos_entries: [macos_entry | state.macos_entries]}
      else
        state
      end

    state =
      if plat_needs.need_windows do
        %{state | windows_entries: [windows_entry | state.windows_entries]}
      else
        state
      end

    if mode == "legacy" do
      diag("Resolved #{ref} → #{sha} (OTP #{major}, bundle-target mode)")
    else
      diag("Resolved #{ref} → #{sha} (OTP #{major}, peer-runner mode, Elixir #{elixir})")
    end

    state
  end

  # OTP < 24's crypto NIF relies on APIs OpenSSL 3 removed. The
  # GHA image ships OpenSSL 3, so drop ssl/ssh/crypto for legacy
  # builds. 24.0/.1 referenced FIPS_mode but our patch stubs that
  # out so they stay on the modern path.
  defp mode_for_major(major) do
    case Integer.parse(major) do
      {n, ""} when n < 24 -> {"legacy", "--without-ssl"}
      _ -> {"modern", ""}
    end
  end

  defp otp_label_for("master:" <> _, _major), do: "master"
  defp otp_label_for("master", _major), do: "master"
  defp otp_label_for("maint", _major), do: "maint"
  defp otp_label_for("maint-" <> _ = ref, _major), do: ref
  defp otp_label_for("OTP-" <> rest, _major), do: rest
  defp otp_label_for(_ref, major), do: major

  defp windows_mapping("master:" <> _, sha, _mode, _otp_label) do
    # install-otp-windows.ps1 walks erlang/otp's GHA runs by head
    # SHA for the otp_win32_installer artifact; pass the bare SHA.
    # The PS1 soft-skips when the artifact's missing (commits with
    # no C changes don't recut the installer).
    {sha, "master"}
  end

  defp windows_mapping("OTP-" <> rest = ref, _sha, "legacy", _otp_label) do
    # Legacy OTPs don't publish patch-version installers; map down
    # to the function-release (X.Y) installer that always exists.
    case String.split(rest, ".") do
      [x, y | _] ->
        xy = "#{x}.#{y}"
        {"OTP-#{xy}", xy}

      _ ->
        {ref, rest}
    end
  end

  defp windows_mapping(ref, _sha, _mode, otp_label), do: {ref, otp_label}

  defp elixir_for_major(state, major) do
    script = Path.join([state.script_dir, "priv", "elixir-for-otp.sh"])

    case state.shell.(script, [major]) do
      {out, 0} -> out |> String.trim() |> String.split("\n") |> List.first()
      {out, code} -> raise "elixir-for-otp.sh failed (exit #{code}):\n#{out}"
    end
  end

  # Cap bundle major at 28 because Elixir hasn't tagged an
  # otp-29 bundle yet (only on the rolling main-latest branch).
  # Bundles are forward-compatible across one major, so otp-28 on
  # OTP-29 works fine.
  defp elixir_bundle_major(major) do
    case Integer.parse(major) do
      {n, ""} when n in 22..28 -> Integer.to_string(n)
      _ -> "28"
    end
  end

  defp commit_timestamp(state, sha) do
    case state.shell.("gh", [
           "api",
           "repos/erlang/otp/commits/#{sha}",
           "--jq",
           ".commit.committer.date // \"\""
         ]) do
      {out, 0} -> out |> String.trim() |> String.split("\n") |> List.first() |> to_string()
      _ -> ""
    end
  end

  # --- gh-pages probes -------------------------------------------

  defp gh_pages_rundirs(state) do
    case state.shell.("gh", [
           "api",
           "repos/#{state.github_repository}/contents?ref=gh-pages",
           "--paginate",
           "--jq",
           ".[].name"
         ]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r/_[0-9a-f]{10}-test-/, &1))

      _ ->
        []
    end
  end

  defp gh_pages_benchees(state) do
    case state.shell.("gh", [
           "api",
           "repos/#{state.github_repository}/git/trees/gh-pages?recursive=1"
         ]) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{"truncated" => true}} ->
            IO.puts(
              :stderr,
              "::warning::gh-pages tree exceeds API page limit; benchmark-targeted skip disabled"
            )

            []

          {:ok, %{"tree" => tree}} when is_list(tree) ->
            for %{"type" => "blob", "path" => path} <- tree,
                String.ends_with?(path, ".benchee"),
                do: path

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp ls_remote(state, ref) do
    case state.shell.("git", ["ls-remote", @otp_git_url, ref]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> List.first()
        |> case do
          nil -> ""
          line -> line |> String.split("\t") |> List.first()
        end

      _ ->
        ""
    end
  end

  defp fetch_otp_version_major(state, sha) do
    case state.shell.("curl", [
           "-fsSL",
           "https://raw.githubusercontent.com/erlang/otp/#{sha}/OTP_VERSION"
         ]) do
      {out, 0} ->
        out
        |> String.trim()
        |> String.split("\n")
        |> List.first()
        |> to_string()
        |> String.split(".")
        |> List.first()
        |> to_string()

      _ ->
        ""
    end
  end

  defp infer_repo_from_origin(shell) do
    case shell.("git", ["remote", "get-url", "origin"]) do
      {out, 0} ->
        out
        |> String.trim()
        |> String.replace(~r"^git@github\.com:", "https://github.com/")
        |> String.replace(~r"\.git$", "")
        |> String.replace(~r"^https://github\.com/", "")

      _ ->
        ""
    end
  end

  # --- finalize --------------------------------------------------

  defp finalize(state) do
    # Reverse so emission order matches input order (we built
    # collectors with prepend-and-reverse for O(1) append).
    linux = Enum.reverse(state.linux_entries)
    macos = Enum.reverse(state.macos_entries)
    windows = Enum.reverse(state.windows_entries)

    {modern_linux, legacy_linux} = split_by_mode(linux)
    {modern_macos, legacy_macos} = split_by_mode(macos)
    {modern_windows, legacy_windows} = split_by_mode(windows)

    # `targets_legacy_build` is the union of all legacy entries
    # deduplicated by major. Drives the build-linux-target +
    # prep-target-bundle jobs that every legacy measure-* job
    # depends on, so a windows-only legacy fill still triggers
    # the shared bundle prep.
    legacy_build =
      (legacy_linux ++ legacy_macos ++ legacy_windows)
      |> Enum.uniq_by(& &1["major"])

    %{
      "targets_modern_linux" => Jason.encode!(modern_linux),
      "targets_modern_macos" => Jason.encode!(modern_macos),
      "targets_modern_windows" => Jason.encode!(modern_windows),
      "targets_legacy_linux" => Jason.encode!(legacy_linux),
      "targets_legacy_macos" => Jason.encode!(legacy_macos),
      "targets_legacy_windows" => Jason.encode!(legacy_windows),
      "targets_legacy_build" => Jason.encode!(legacy_build),
      "has_modern_linux" => boolish(modern_linux),
      "has_modern_macos" => boolish(modern_macos),
      "has_modern_windows" => boolish(modern_windows),
      "has_legacy_linux" => boolish(legacy_linux),
      "has_legacy_macos" => boolish(legacy_macos),
      "has_legacy_windows" => boolish(legacy_windows),
      "has_legacy_build" => boolish(legacy_build)
    }
  end

  defp split_by_mode(entries),
    do: Enum.split_with(entries, &(&1["mode"] == "modern"))

  defp boolish([]), do: "false"
  defp boolish(_), do: "true"

  defp emit_diagnostics(state) do
    if state.n_master_dropped > 0 do
      IO.puts(
        :stderr,
        "::notice::deferred #{state.n_master_dropped} master:<sha> merges " <>
          "(cap MAX_MASTER_MERGES=#{state.max_master_merges}); next fill picks them up"
      )
    end
  end

  # --- helpers ---------------------------------------------------

  defp csv_to_list(""), do: []
  defp csv_to_list(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_shell(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  end

  defp diag(msg), do: IO.puts(:stderr, msg)
end
