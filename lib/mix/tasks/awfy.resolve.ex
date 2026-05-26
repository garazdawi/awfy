# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Awfy.Resolve do
  @shortdoc "Resolve a CSV of OTP refs into per-platform GHA matrix outputs"
  @moduledoc """
  CLI wrapper for `Awfy.Fill.Resolve.resolve/2`. The bench.yml resolve
  step shells out to this task; the implementation lives in
  `Awfy.Fill.Resolve` so unit tests can drive it in-process with a
  stub `:shell`.

  ## Usage

      mix awfy.resolve "OTP-28.5,master,master:abc...def"

  Env-var inputs (read by `run/1`):

  | Env var               | Default     | Meaning                                                          |
  | --------------------- | ----------- | ---------------------------------------------------------------- |
  | `FILL_MODE`           | `0`         | `1` enables the gh-pages skip check.                             |
  | `INPUT_BENCHMARKS`    | empty       | comma-separated benchmark names; overrides canonical synthetic.  |
  | `CANONICAL_SYNTHETIC` | empty       | canonical synthetic suite from `mix awfy.measure --dry-run`.     |
  | `CANONICAL_XMPP`      | empty       | canonical XMPP scenarios from `mix awfy.measure_xmpp --dry-run`. |
  | `MAX_MASTER_MERGES`   | `50`        | cap on `master:<sha>` entries kept per run; `0` disables.        |
  | `SKIP_PLATFORMS`      | empty       | comma-separated platforms (`macos`, etc.) the workflow can't measure; the resolver ignores them in the gap check so a SHA whose only missing slot is that platform gets skipped. |
  | `GITHUB_REPOSITORY`   | origin      | `owner/repo` for gh-pages probes.                                |
  | `GITHUB_OUTPUT`       | stdout      | path to GHA outputs file. Falls back to stdout for local runs.   |
  | `GH_TOKEN`            | -           | propagated to `gh api` via the inherited env.                    |

  Outputs are GHA `key=value` lines — see `Awfy.Fill.Resolve` for the
  full list and per-entry JSON shape.
  """

  use Mix.Task

  alias Awfy.Fill.Resolve

  @impl true
  def run([refs_csv]) do
    Mix.Task.run("app.start", [])

    opts = [
      fill_mode: System.get_env("FILL_MODE", "0") == "1",
      input_benchmarks: System.get_env("INPUT_BENCHMARKS", ""),
      canonical_synthetic: System.get_env("CANONICAL_SYNTHETIC", ""),
      canonical_xmpp: System.get_env("CANONICAL_XMPP", ""),
      max_master_merges:
        System.get_env("MAX_MASTER_MERGES", "50")
        |> Integer.parse()
        |> case do
          {n, _} -> n
          _ -> 50
        end,
      skip_platforms:
        System.get_env("SKIP_PLATFORMS", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    ]

    outputs = Resolve.resolve(refs_csv, opts)
    emit(outputs)
  end

  def run(_) do
    Mix.shell().error("usage: mix awfy.resolve <comma-separated-refs>")
    System.halt(2)
  end

  defp emit(outputs) do
    body =
      outputs
      |> Enum.map(fn {k, v} -> "#{k}=#{v}\n" end)
      |> Enum.join()

    case System.get_env("GITHUB_OUTPUT") do
      nil -> IO.write(body)
      "" -> IO.write(body)
      path -> File.write!(path, body, [:append])
    end
  end
end
