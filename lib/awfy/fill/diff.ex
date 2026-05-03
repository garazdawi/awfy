# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Fill.Diff do
  @moduledoc """
  Pure functions used by `Mix.Tasks.Awfy.Fill` to diff what's already
  on `gh-pages` against what *should* be there for the current
  platform. Extracted so the matrix logic — which decides what gets
  measured next — can be tested without touching git or the network.

  ## Run-dir naming contract

  Run directories under `gh-pages/` are named:

      <ts>_otp<release>_elixir<version>_<otp_short>-<os>-<arch>-<flavor>

  where the suffix label is built by `Mix.Tasks.Awfy.Measure` from the
  fill task's `--label` argument. Anything that doesn't match is
  ignored (e.g. dashboard HTML, README, `.nojekyll`).
  """

  @typedoc "A parsed run-dir entry."
  @type entry :: %{
          run_dir: String.t(),
          timestamp: String.t(),
          otp_sha: String.t(),
          platform: String.t(),
          flavor: String.t()
        }

  @doc """
  Parse a `gh-pages` directory name into platform/flavor components.
  Returns `nil` for anything that doesn't match the AWFY run-dir
  shape — callers filter `nil` out.
  """
  @spec parse_run_dir(String.t()) :: entry() | nil
  def parse_run_dir(name) do
    case Regex.run(~r/^(\d{8}T\d{4})_otp([^_]+)_elixir([^_]+)_(.+)$/, name) do
      [_, ts, _otp_release, _elixir, label] ->
        case String.split(label, "-") do
          [otp_short, os, arch, flavor] ->
            %{
              run_dir: name,
              timestamp: ts,
              otp_sha: otp_short,
              platform: "#{os}-#{arch}",
              flavor: flavor
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Given the parsed entries already on gh-pages, the platform we're
  filling for, and the flavors we care about, return the list of
  `{sha, flavor}` pairs we should run, newest-first.

  The "universe" of SHAs we expect is "every SHA seen on any
  platform"; this lets Linux's daily run be the de-facto schedule
  without hard-coding it. If `since` is provided (`YYYY-MM-DD`),
  only SHAs whose earliest sighting on any platform is at-or-after
  the cutoff are considered.
  """
  @spec compute_missing([entry()], String.t(), [String.t()], String.t() | nil) ::
          [{String.t(), String.t()}]
  def compute_missing(existing, platform, flavors, since) do
    have = MapSet.new(existing, fn r -> {r.otp_sha, r.platform, r.flavor} end)

    all_shas =
      existing
      |> Enum.map(& &1.otp_sha)
      |> Enum.uniq()
      |> filter_since(existing, since)

    for sha <- all_shas,
        flavor <- flavors,
        not MapSet.member?(have, {sha, platform, flavor}) do
      {sha, flavor}
    end
    |> Enum.sort_by(
      fn {sha, _flavor} ->
        existing
        |> Enum.filter(&(&1.otp_sha == sha))
        |> Enum.map(& &1.timestamp)
        |> Enum.max()
      end,
      :desc
    )
  end

  @spec filter_since([String.t()], [entry()], String.t() | nil) :: [String.t()]
  def filter_since(shas, _existing, nil), do: shas

  def filter_since(shas, existing, since) do
    cutoff = String.replace(since, "-", "") <> "T0000"

    Enum.filter(shas, fn sha ->
      ts =
        existing
        |> Enum.filter(&(&1.otp_sha == sha))
        |> Enum.map(& &1.timestamp)
        |> Enum.min(fn -> "00000000T0000" end)

      ts >= cutoff
    end)
  end

  @doc """
  Detect the platform tag (`<os>-<arch>`) for the current machine.
  Maps `:erlang.system_info(:system_architecture)` (which embeds the
  full target triple, e.g. `aarch64-apple-darwin23.4.0`) down to a
  short, stable label that matches the convention in
  `bin/install-otp-source.sh` and the GitHub Actions matrix.
  """
  @spec detect_platform(:os.osname(), String.t()) :: String.t()
  def detect_platform(os_type, system_architecture) do
    arch = arch_string(system_architecture)

    case os_type do
      {:unix, :darwin} -> "macos-#{arch}"
      {:unix, :linux} -> "linux-#{arch}"
      {:win32, _} -> "windows-#{arch}"
      {family, name} -> "#{family}-#{name}-#{arch}"
    end
  end

  @spec arch_string(String.t()) :: String.t()
  def arch_string(sysarch) do
    cond do
      sysarch =~ "aarch64" or sysarch =~ "arm64" -> "arm64"
      sysarch =~ "x86_64" or sysarch =~ "amd64" -> "x86_64"
      true -> sysarch |> String.split("-") |> hd()
    end
  end

  @spec maybe_limit([term()], integer() | nil) :: [term()]
  def maybe_limit(list, nil), do: list
  def maybe_limit(list, n) when is_integer(n) and n > 0, do: Enum.take(list, n)

  @spec parse_csv(String.t() | nil) :: [String.t()] | nil
  def parse_csv(nil), do: nil
  def parse_csv(s), do: String.split(s, ",", trim: true)
end
