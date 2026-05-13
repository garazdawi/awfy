# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.RunContext do
  @moduledoc """
  Collapses every "what's the OTP version / emu flavor / Elixir
  version / git state / timestamp / label" question a measure task
  asks into one validated struct, built once at the start of the
  task by `RunContext.new/1`.

  Before this module existed, the same questions were answered six
  different times across `Mix.Tasks.Awfy.Measure`,
  `Mix.Tasks.Awfy.MeasureXmpp`, `Awfy.Measure.Helpers`,
  `Awfy.Compare.Data`, and CI env vars — and they routinely
  disagreed. `Awfy.Compare.Data` explicitly contradicts the meta
  file's `runtime.emu_flavor` with an override derived from the
  label suffix because the host's runtime info is the wrong thing
  to record on bundle-mode or container-orchestrated runs. The
  `timestamp` resolver in `Helpers.trend_timestamp/0` carries a
  comment about a months-old config bug that the old silent-
  fallback semantics hid. PLAN/INFRA_REFACTOR.md § 3.

  Two principles guide the design:

  1. **One resolution point.** Every writer builds a `RunContext`
     once via `new/1`, passes it to `Awfy.Measure.Meta.write/2`,
     and never re-reads env vars. The reader (the dashboard's
     `Awfy.Compare.Data`) consumes the resulting fields directly
     without any "if the writer was wrong, override here"
     workaround.

  2. **The label suffix wins over runtime info for `emu_flavor`.**
     This matches what the dashboard reader does today via
     `flavor_from_label/1`, but moves the decision to write time so
     `meta.json` is honest about which BEAM actually ran. Bundle-
     mode runs and XMPP-broker-in-container runs both fall under
     this — the host BEAM that builds the meta is NOT the one that
     produced the measurements.

  The `:flavor_source` field records *why* the chosen flavor was
  picked, so future debugging can trace a misclassification back to
  the writer rather than the reader.
  """

  @enforce_keys [
    :otp_label,
    :otp_release,
    :elixir_version,
    :emu_flavor,
    :flavor_source,
    :schedulers,
    :trend_timestamp,
    :git_sha,
    :git_dirty,
    :label,
    :scenario
  ]
  defstruct @enforce_keys

  @type scenario_tag :: :synthetic | :otp_benchmarks | :xmpp | :network

  @type t :: %__MODULE__{
          otp_label: String.t(),
          otp_release: String.t(),
          elixir_version: String.t(),
          emu_flavor: :jit | :emu,
          flavor_source: :label | :runtime,
          schedulers: pos_integer(),
          trend_timestamp: DateTime.t(),
          git_sha: String.t(),
          git_dirty: boolean(),
          label: String.t(),
          scenario: scenario_tag()
        }

  @doc """
  Build a `RunContext` from caller-supplied options and the
  ambient environment (env vars + `System.*` functions).

  Required options:
    * `:scenario` — `:synthetic | :otp_benchmarks | :xmpp | :network`,
      the tag identifying which measure task built this context.
      Drives nothing today; future per-scenario branches in
      `Meta.write/2` will consume it.

  Optional options (testing seams):
    * `:label` — caller-supplied label string (e.g. `--label v1`).
      When omitted, falls through to `Helpers.auto_label/3`.
    * `:now` — `DateTime` used for the `auto_label` timestamp when
      git is dirty. Defaults to `DateTime.utc_now/0`.
    * `:env` — map of env-var lookups (for tests). Defaults to
      `System.get_env/1`.
    * `:elixir_version` — caller override. Defaults to the
      `AWFY_TARGET_ELIXIR_VERSION` env var or `System.version/0`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    scenario = Keyword.fetch!(opts, :scenario)
    env = Keyword.get(opts, :env, &System.get_env/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {git_sha, git_dirty?} = git_state()

    otp_label = otp_label_for_env(env)
    otp_release = to_string(System.otp_release())
    elixir_version = Keyword.get(opts, :elixir_version) || target_elixir_version(env)

    label = Keyword.get(opts, :label) || Awfy.Measure.Helpers.auto_label(git_sha, git_dirty?, now)
    {emu_flavor, flavor_source} = resolve_emu_flavor(label)

    trend_timestamp = Awfy.Measure.Helpers.trend_timestamp()

    %__MODULE__{
      otp_label: otp_label,
      otp_release: otp_release,
      elixir_version: elixir_version,
      emu_flavor: emu_flavor,
      flavor_source: flavor_source,
      schedulers: :erlang.system_info(:schedulers_online),
      trend_timestamp: trend_timestamp,
      git_sha: git_sha,
      git_dirty: git_dirty?,
      label: label,
      scenario: scenario
    }
  end

  @doc """
  Resolve emu flavor from a label. Public for unit testing — same
  rule the dashboard's `flavor_from_label/1` applies. Returns the
  resolved atom plus a `:source` tag indicating where the value
  came from (label suffix vs runtime fallback).
  """
  @spec resolve_emu_flavor(String.t() | nil) :: {:jit | :emu, :label | :runtime}
  def resolve_emu_flavor(label) when is_binary(label) do
    case String.split(label, "-") |> List.last() do
      "jit" -> {:jit, :label}
      "emu" -> {:emu, :label}
      _ -> {runtime_flavor(), :runtime}
    end
  end

  def resolve_emu_flavor(_), do: {runtime_flavor(), :runtime}

  defp runtime_flavor do
    case :erlang.system_info(:emu_flavor) do
      :jit -> :jit
      :emu -> :emu
      _ -> :jit
    end
  end

  defp otp_label_for_env(env) do
    case env.("AWFY_OTP_VERSION") do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        Awfy.Measure.Helpers.otp_version_label_from_file() || to_string(System.otp_release())
    end
  end

  defp target_elixir_version(env) do
    case env.("AWFY_TARGET_ELIXIR_VERSION") do
      v when is_binary(v) and v != "" -> v
      _ -> System.version()
    end
  end

  defp git_state do
    sha = git(["rev-parse", "--short", "HEAD"]) || "unknown"
    dirty? = (git(["status", "--porcelain"]) || "") != ""
    {sha, dirty?}
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end
end
