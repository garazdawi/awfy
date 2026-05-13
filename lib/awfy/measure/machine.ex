# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.Machine do
  @moduledoc """
  One-place "describe the host" probe — used by every measure
  task's meta.json writer. The result populates the `machine` block:

      %{
        "hostname" => "lukas-m5",
        "os"       => "Darwin 25.4.0",
        "cpu"      => "Apple M5",
        "arch"     => "aarch64-apple-darwin25.4.0",
        "cores"    => 10,
        "platform" => "macos-arm64"        # canonical "<os>-<arch>"
      }

  Before this module existed, each writer (`Mix.Tasks.Awfy.Measure`,
  `Mix.Tasks.Awfy.MeasureXmpp`) carried its own byte-identical
  `os_string/0`, `cpu_string/0`, `trim_cmd/2` copies — three OS
  dispatches in lockstep across two files, and `awfy.preflight`
  carried a fourth `sysctl_int("hw.ncpu")` probe that disagreed
  with the writers' `System.schedulers_online()` on hosts running
  with `+S 2`. PLAN/INFRA_REFACTOR.md § 4.

  `platform/0` is also exposed standalone; it's the canonical
  `linux-x86_64` / `macos-arm64` / `windows-x86_64` form that
  `Awfy.Fill.Diff.detect_platform/2` derives. Threading the same
  string from this single probe through meta.json means downstream
  consumers stop having to reverse-engineer it from `os`+`arch`.
  """

  @typedoc "Shape of the `machine` block in meta.json."
  @type t :: %{
          required(String.t()) => String.t() | pos_integer()
        }

  @doc """
  Probe the host once and return the meta.json `machine` block.
  All values are stringy except `cores`. Best-effort: any probe
  that fails returns a non-empty fallback string so the meta
  schema validator stays happy.
  """
  @spec describe() :: t()
  def describe do
    {:ok, hostname_charlist} = :inet.gethostname()

    %{
      "hostname" => List.to_string(hostname_charlist),
      "os" => os_string(),
      "cpu" => cpu_string(),
      "arch" => to_string(:erlang.system_info(:system_architecture)),
      # NB: `System.schedulers_online()` reflects the BEAM's scheduler
      # count which `+S N` constrains, NOT the host's logical
      # processor count. On a `+S 2` host this reads 2 even when the
      # machine has 10 cores — disagrees with `awfy.preflight`'s
      # `sysctl_int("hw.ncpu")`. Kept here for behaviour-parity with
      # the pre-refactor writers; flipping to
      # `:erlang.system_info(:logical_processors)` is a separate
      # decision because it would shift every prior run's machine.cores.
      "cores" => System.schedulers_online(),
      "platform" => platform()
    }
  end

  @doc """
  Canonical `<os>-<arch>` platform string. Today's values:
  `linux-x86_64`, `linux-arm64`, `macos-x86_64`, `macos-arm64`,
  `windows-x86_64`, `windows-arm64`. Falls through to
  `unknown-<arch>` for unrecognised OS types.

  Matches `Awfy.Fill.Diff.detect_platform/2`'s output so meta.json
  and the fill discovery agree on the same string.
  """
  @spec platform() :: String.t()
  def platform do
    arch = arch_short()

    case :os.type() do
      {:unix, :darwin} -> "macos-#{arch}"
      {:unix, :linux} -> "linux-#{arch}"
      {:win32, _} -> "windows-#{arch}"
      _ -> "unknown-#{arch}"
    end
  end

  defp arch_short do
    case to_string(:erlang.system_info(:system_architecture)) do
      "aarch64" <> _ -> "arm64"
      "arm64" <> _ -> "arm64"
      "arm" <> _ -> "arm64"
      "x86_64" <> _ -> "x86_64"
      "amd64" <> _ -> "x86_64"
      other -> other |> String.split("-") |> hd()
    end
  end

  defp os_string do
    case :os.type() do
      {:unix, :darwin} -> trim_cmd("uname", ["-sr"]) || "Darwin"
      {:unix, :linux} -> trim_cmd("uname", ["-sr"]) || "Linux"
      {family, name} -> "#{family}/#{name}"
    end
  end

  defp cpu_string do
    case :os.type() do
      {:unix, :darwin} ->
        trim_cmd("sysctl", ["-n", "machdep.cpu.brand_string"]) || "unknown"

      {:unix, :linux} ->
        with {:ok, bin} <- File.read("/proc/cpuinfo"),
             field when is_binary(field) <- Awfy.Preflight.Parse.cpuinfo_field(bin, "model name") do
          field
        else
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp trim_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end
end
