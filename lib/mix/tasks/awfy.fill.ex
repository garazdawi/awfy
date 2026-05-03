# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.Fill do
  @shortdoc "Backfill missing benchmark results for the current platform"
  @moduledoc """
  Walks the `gh-pages` branch, finds OTP commits that have results
  from some platforms but not the current one, and runs the missing
  measurements locally. Cross-platform: detects current OS + arch
  via `:os.type/0` and dispatches to the right installer.

  Designed to replace platform-specific runner daemons. Any machine
  (your M5, a Windows VM, a Linux ARM box) can fill in its slice of
  the benchmark matrix at the operator's leisure.

  ## Usage

      mix awfy.fill                      # find missing SHAs, run, commit locally
      mix awfy.fill --max 3              # cap N runs per invocation
      mix awfy.fill --since 2026-04-01   # only SHAs newer than this date
      mix awfy.fill --shas abc,def       # explicit SHA list, skip gh-pages query
      mix awfy.fill --dry-run            # show what would run, do nothing
      mix awfy.fill --platform linux-x86_64
                                          # override platform detection
      mix awfy.fill --flavors jit        # subset of {jit, emu}
      mix awfy.fill --pages-dir <path>   # alternate gh-pages worktree path

  Results land in `_pages/` (a worktree of the gh-pages branch),
  committed locally. The task **never pushes** — when satisfied
  with the new run-dirs, run:

      git -C _pages push origin gh-pages

  ## See also

  - `FILL_TASK_PLAN.md` — design rationale.
  - `mix awfy.measure` — what gets invoked per missing SHA.
  - `mix awfy.compare` — dashboard regeneration after merging runs.
  """

  use Mix.Task

  alias Awfy.Fill.Diff

  @switches [
    max: :integer,
    since: :string,
    shas: :string,
    dry_run: :boolean,
    platform: :string,
    pages_dir: :string,
    flavors: :string
  ]

  @flavors_default ["jit", "emu"]

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    platform = opts[:platform] || detect_platform()
    flavors = Diff.parse_csv(opts[:flavors]) || @flavors_default
    pages_dir = opts[:pages_dir] || "_pages"

    Mix.shell().info("[fill] platform=#{platform} flavors=#{Enum.join(flavors, ",")}")

    pages = ensure_pages_worktree(pages_dir)

    target =
      case opts[:shas] do
        nil ->
          existing = scan_existing(pages)
          missing = Diff.compute_missing(existing, platform, flavors, opts[:since])
          Diff.maybe_limit(missing, opts[:max])

        s ->
          shas = String.split(s, ",", trim: true)
          for sha <- shas, flavor <- flavors, do: {sha, flavor}
      end

    cond do
      target == [] ->
        Mix.shell().info("[fill] nothing to do — gh-pages already has #{platform} for every SHA")

      opts[:dry_run] ->
        Mix.shell().info("[fill] would run #{length(target)} measurement(s):")

        Enum.each(target, fn {sha, flavor} ->
          Mix.shell().info("       #{sha} / #{flavor}")
        end)

      true ->
        Mix.shell().info("[fill] running #{length(target)} measurement(s)…")

        results =
          Enum.map(target, fn {sha, flavor} -> run_one(sha, flavor, platform, pages) end)

        ok = Enum.count(results, &(&1 == :ok))
        Mix.shell().info("[fill] done — #{ok}/#{length(results)} successful")

        if ok > 0 do
          commit_pages(pages)

          Mix.shell().info("""

          [fill] new run-dirs committed to local gh-pages worktree at #{pages}.
                 review with:    git -C #{pages} log -1 --stat
                 publish with:   git -C #{pages} push origin gh-pages
          """)
        end
    end
  end

  defp detect_platform do
    Diff.detect_platform(:os.type(), to_string(:erlang.system_info(:system_architecture)))
  end

  # ===================================================================
  # gh-pages worktree
  # ===================================================================

  defp ensure_pages_worktree(dir) do
    abs_dir = Path.expand(dir)

    cond do
      worktree?(abs_dir) ->
        # Pull updates if there's an origin/gh-pages to pull from; otherwise
        # this is an orphan worktree from a prior bootstrap, leave it alone.
        if remote_has_branch?("gh-pages") do
          {_, 0} = System.cmd("git", ["-C", abs_dir, "fetch", "origin", "gh-pages"])
          {_, 0} = System.cmd("git", ["-C", abs_dir, "reset", "--hard", "origin/gh-pages"])
        end

        abs_dir

      File.exists?(abs_dir) ->
        Mix.raise("#{abs_dir} exists but isn't a git worktree — remove it or use --pages-dir")

      remote_has_branch?("gh-pages") ->
        {_, 0} = System.cmd("git", ["fetch", "origin", "gh-pages"])

        {_, 0} =
          System.cmd("git", ["worktree", "add", "-B", "gh-pages", abs_dir, "origin/gh-pages"])

        abs_dir

      true ->
        {_, 0} = System.cmd("git", ["worktree", "add", "--orphan", "-b", "gh-pages", abs_dir])
        File.cd!(abs_dir, fn -> System.cmd("git", ["rm", "-rf", "."], stderr_to_stdout: true) end)
        abs_dir
    end
  end

  # In a git worktree, `.git` is a regular file ("gitdir: …") pointing at
  # the main repo. In a plain clone, `.git` is a directory. In a bare
  # checkout, there's no `.git` at all but `HEAD` lives at the root.
  defp worktree?(dir) do
    File.exists?(Path.join(dir, ".git")) or File.exists?(Path.join(dir, "HEAD"))
  end

  defp remote_has_branch?(branch) do
    case System.cmd("git", ["ls-remote", "--exit-code", "--heads", "origin", branch],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  # ===================================================================
  # Scan existing run-dirs on gh-pages
  # ===================================================================

  defp scan_existing(pages_dir) do
    pages_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(pages_dir, &1)))
    |> Enum.map(&Diff.parse_run_dir/1)
    |> Enum.reject(&is_nil/1)
  end

  # ===================================================================
  # Run a single measurement
  # ===================================================================

  defp run_one(otp_sha, flavor, platform, pages_dir) do
    Mix.shell().info("[fill] #{otp_sha}/#{flavor} on #{platform}")

    with {:ok, otp_prefix} <- install_otp(otp_sha),
         env <- build_env(otp_prefix, otp_sha, flavor),
         {:ok, results_dir} <- run_measure(env, otp_sha, platform, flavor),
         :ok <- move_results_to_pages(results_dir, pages_dir) do
      :ok
    else
      {:error, msg} ->
        Mix.shell().error("[fill] #{otp_sha}/#{flavor}: #{msg}")
        :error
    end
  end

  defp install_otp(otp_sha) do
    case :os.type() do
      {:unix, _} ->
        run_capture("bash", ["bin/install-otp-source.sh", otp_sha])

      {:win32, _} ->
        run_capture("powershell", [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          "bin/install-otp-windows.ps1",
          "-OtpRef",
          otp_sha
        ])
    end
  end

  defp run_capture(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: false) do
      {out, 0} ->
        prefix =
          out
          |> String.trim()
          |> String.split("\n")
          |> List.last()
          |> String.trim()

        if File.dir?(prefix),
          do: {:ok, prefix},
          else: {:error, "installer didn't print a valid prefix: #{inspect(prefix)}"}

      {out, code} ->
        {:error, "#{cmd} exited #{code}: #{String.slice(out, 0, 500)}"}
    end
  end

  # Per-SHA build dir (`MIX_BUILD_PATH`) prevents .beam contamination
  # across OTP versions in a shared `_build/`.
  defp build_env(otp_prefix, otp_sha, flavor) do
    bin_path = Path.join(otp_prefix, "bin")
    sep = if match?({:win32, _}, :os.type()), do: ";", else: ":"
    new_path = bin_path <> sep <> System.get_env("PATH", "")

    erl_flags =
      case flavor do
        "emu" -> "-emu_flavor emu"
        _ -> ""
      end

    [
      {"PATH", new_path},
      {"MIX_BUILD_PATH", "_build/#{otp_sha}"},
      {"ERL_FLAGS", erl_flags}
    ]
  end

  defp run_measure(env, otp_sha, platform, flavor) do
    label = "#{String.slice(otp_sha, 0, 10)}-#{platform}-#{flavor}"
    out_dir = Path.join("_fill_results", label)
    File.mkdir_p!(out_dir)

    steps = [
      ["local.hex", "--force"],
      ["local.rebar", "--force"],
      ["deps.get"],
      ["compile"],
      ["awfy.measure", "--label", label, "--ignore-preflight", "--out", out_dir]
    ]

    Enum.reduce_while(steps, {:ok, out_dir}, fn args, _ ->
      case System.cmd("mix", args, env: env) do
        {_, 0} ->
          {:cont, {:ok, out_dir}}

        {out, code} ->
          {:halt, {:error, "mix #{hd(args)} exited #{code}: #{String.slice(out || "", 0, 500)}"}}
      end
    end)
  end

  defp move_results_to_pages(results_dir, pages_dir) do
    File.ls!(results_dir)
    |> Enum.filter(&File.dir?(Path.join(results_dir, &1)))
    |> Enum.each(fn run ->
      src = Path.join(results_dir, run)
      dst = Path.join(pages_dir, run)
      unless File.exists?(dst), do: File.cp_r!(src, dst)
    end)

    File.rm_rf!(results_dir)
    :ok
  end

  # ===================================================================
  # Commit (no push)
  # ===================================================================

  defp commit_pages(pages_dir) do
    Mix.shell().info("[fill] regenerating dashboard…")
    {_, 0} = System.cmd("mix", ["awfy.compare", "--out", pages_dir])
    {_, 0} = System.cmd("git", ["-C", pages_dir, "add", "-A"])

    case System.cmd("git", ["-C", pages_dir, "diff", "--staged", "--quiet"]) do
      {_, 0} ->
        Mix.shell().info("[fill] no changes to commit")

      {_, 1} ->
        msg = "fill: #{Date.utc_today()} (#{System.get_env("USER", "fill")})"
        {_, 0} = System.cmd("git", ["-C", pages_dir, "commit", "-m", msg])
    end
  end
end
