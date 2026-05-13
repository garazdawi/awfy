# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.MetaSchema do
  @moduledoc """
  One-place schema for the `meta.json` file every measure task writes.

  The three writers (`Mix.Tasks.Awfy.Measure`, `Mix.Tasks.Awfy.MeasureXmpp`,
  and any future per-scenario task) all produce slightly different
  shapes of this map; this validator is the single contract they share
  with the dashboard (`Awfy.Compare.Data`).

  Each writer's unit test should round-trip its output through
  `validate!/1` so a field omission or rename surfaces at write time
  rather than weeks later as a silent dashboard hole. The CI smoke
  layer in `test/smoke/` re-runs the same validator against the
  artifacts of a real `mix awfy.measure` so a refactor that
  decouples writers from `Meta.write/2` doesn't quietly drift.

  Required fields (always):
    * `format_version`     — integer, ≥ 1.
    * `label`              — non-empty string. Dashboard's series key.
    * `otp`                — non-empty string. Dashboard's trend x-axis.
    * `elixir`             — non-empty string, semver-ish.
    * `timestamp`          — ISO 8601 string, parseable by `DateTime.from_iso8601/1`.
    * `git.sha`            — non-empty string.
    * `git.dirty`          — boolean.
    * `machine.hostname`   — non-empty string.
    * `machine.os`         — non-empty string.
    * `machine.cpu`        — non-empty string.
    * `machine.arch`       — non-empty string.
    * `machine.cores`      — positive integer.

  Optional fields (one of these blocks SHOULD be present so the
  dashboard has something to render, but the validator accepts
  empty maps):
    * `runtime` — emu_flavor + scheduler/wordsize/c_compiler info.
      Currently omitted by the XMPP writer; §1 refactor adds it back.
    * `config`  — Benchee time/warmup/lang/build_flags.
    * `benchmarks`       — AWFY synthetic per-benchmark meta.
    * `otp_benchmarks`   — OtpBenchmarks per-family meta.
    * `xmpp`             — XMPP scenario block (raw sample arrays).
    * `applications`     — declares per-application family + metrics.

  See `PLAN/INFRA_REFACTOR.md` § 1 for the longer story.
  """

  @typedoc "Result of validate/1 — :ok or a list of human-readable errors."
  @type result :: :ok | {:error, [String.t()]}

  @doc """
  Validate a decoded meta.json map. Returns `:ok` or `{:error, [reason]}`.
  Use `validate!/1` if you want a raise on failure.
  """
  @spec validate(map()) :: result()
  def validate(meta) when is_map(meta) do
    errors =
      []
      |> check_format_version(meta)
      |> check_required_string(meta, "label")
      |> check_required_string(meta, "otp")
      |> check_required_string(meta, "elixir")
      |> check_timestamp(meta)
      |> check_git_block(meta)
      |> check_machine_block(meta)
      |> check_optional_runtime(meta)

    case Enum.reverse(errors) do
      [] -> :ok
      list -> {:error, list}
    end
  end

  def validate(_), do: {:error, ["meta is not a map"]}

  @doc """
  Same as `validate/1` but raises on failure with all errors at once.
  Use in tests so a single run-through catches every problem rather
  than relying on the next field's assert to surface the next bug.
  """
  @spec validate!(map()) :: :ok
  def validate!(meta) do
    case validate(meta) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError, "meta.json failed schema validation:\n  " <> Enum.join(errors, "\n  ")
    end
  end

  defp check_format_version(errors, meta) do
    case Map.get(meta, "format_version") do
      v when is_integer(v) and v >= 1 -> errors
      other -> ["format_version: expected positive integer, got #{inspect(other)}" | errors]
    end
  end

  defp check_required_string(errors, meta, key) do
    case Map.get(meta, key) do
      s when is_binary(s) and byte_size(s) > 0 -> errors
      other -> ["#{key}: expected non-empty string, got #{inspect(other)}" | errors]
    end
  end

  defp check_timestamp(errors, meta) do
    case Map.get(meta, "timestamp") do
      s when is_binary(s) ->
        case DateTime.from_iso8601(s) do
          {:ok, _, _} -> errors
          {:error, why} -> ["timestamp: not ISO 8601 (#{inspect(why)})" | errors]
        end

      other ->
        ["timestamp: expected ISO 8601 string, got #{inspect(other)}" | errors]
    end
  end

  defp check_git_block(errors, meta) do
    case Map.get(meta, "git") do
      %{"sha" => sha, "dirty" => dirty} when is_binary(sha) and is_boolean(dirty) -> errors
      other -> ["git: expected %{\"sha\" => binary, \"dirty\" => boolean}, got #{inspect(other)}" | errors]
    end
  end

  defp check_machine_block(errors, meta) do
    case Map.get(meta, "machine") do
      %{} = m ->
        errors
        |> machine_required_string(m, "hostname")
        |> machine_required_string(m, "os")
        |> machine_required_string(m, "cpu")
        |> machine_required_string(m, "arch")
        |> machine_cores(m)

      other ->
        ["machine: expected map, got #{inspect(other)}" | errors]
    end
  end

  defp machine_required_string(errors, machine, key) do
    case Map.get(machine, key) do
      s when is_binary(s) and byte_size(s) > 0 -> errors
      other -> ["machine.#{key}: expected non-empty string, got #{inspect(other)}" | errors]
    end
  end

  defp machine_cores(errors, machine) do
    case Map.get(machine, "cores") do
      n when is_integer(n) and n > 0 -> errors
      other -> ["machine.cores: expected positive integer, got #{inspect(other)}" | errors]
    end
  end

  # `runtime` is currently optional — the XMPP writer omits it
  # (PLAN/INFRA_REFACTOR.md § 1). Once §1 lands and the unified writer
  # always emits it, flip this check to "required". For now accept
  # missing/empty but reject malformed shapes (e.g. a list).
  defp check_optional_runtime(errors, meta) do
    case Map.get(meta, "runtime") do
      nil -> errors
      %{} -> errors
      other -> ["runtime: expected map or omitted, got #{inspect(other)}" | errors]
    end
  end
end
