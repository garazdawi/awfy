# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.Meta do
  @moduledoc """
  One-place builder for the `meta.json` file every measure task
  writes. Before this module existed, each task carried its own
  near-identical JSON-structure literal that diverged silently —
  the XMPP writer omitted the entire `runtime` + `config` blocks,
  the AWFY writer had a richer `runtime`, and both reimplemented
  identical `git_state/0` + machine probes. PLAN/INFRA_REFACTOR.md
  § 1.

  Two functions:

  * `base/2` builds the *derived* portion of the map: format_version,
    label, otp, elixir, timestamp, git, machine, runtime. Identical
    for every measure task — only the source (`RunContext`) varies.

  * `write/3` deep-merges scenario-specific fields (the `benchmarks`,
    `otp_benchmarks`, `xmpp`, `applications`, or future `network`
    block) on top of `base/2` and writes the file. Returns the
    rendered map so callers can validate or log it.

  Validation hooks into `Awfy.Measure.MetaSchema.validate!/1` before
  writing — so a writer that omits a required field surfaces as a
  raise at write time, not weeks later as a blank dashboard cell.
  """

  alias Awfy.Measure.{Machine, MetaSchema}
  alias Awfy.RunContext

  @format_version 2

  @doc """
  Return the format version the current writer emits. Bumped from 1
  to 2 in the §1 unification (XMPP runs now carry the `runtime` +
  `config` blocks the AWFY writer always emitted; dashboard handles
  both via the missing-field-tolerant readers in
  `Awfy.Compare.Data`).
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Build the derived (non-scenario-specific) portion of meta.json
  from a `RunContext` plus optional `runtime_extras` and `config`
  blocks for the synthetic-AWFY writer's extra fields.

  Options:
    * `:runtime_extras` — map of extra `runtime` fields the synthetic
      writer wants (logical_processors, wordsize, c_compiler_used,
      etc. — fields RunContext doesn't carry because they're write-
      time descriptive rather than load-bearing for dashboard logic).
    * `:config` — map for the `config` block (Benchee `time`/`warmup`/
      `lang`/`build_flags`). Omitted for application-bench writers.
  """
  @spec base(RunContext.t(), keyword()) :: map()
  def base(%RunContext{} = rc, opts \\ []) do
    runtime_extras = Keyword.get(opts, :runtime_extras, %{})
    config = Keyword.get(opts, :config)

    runtime =
      Map.merge(
        %{
          "emu_flavor" => to_string(rc.emu_flavor),
          "flavor_source" => to_string(rc.flavor_source),
          "schedulers_online" => rc.schedulers
        },
        runtime_extras
      )

    base = %{
      "format_version" => @format_version,
      "label" => rc.label,
      "otp" => rc.otp_label,
      "elixir" => rc.elixir_version,
      "timestamp" => DateTime.to_iso8601(rc.trend_timestamp),
      "git" => %{"sha" => rc.git_sha, "dirty" => rc.git_dirty},
      "machine" => Machine.describe(),
      "runtime" => runtime
    }

    if config, do: Map.put(base, "config", config), else: base
  end

  @doc """
  Merge `scenario_block` (a map of extra top-level keys) onto
  `base/2`'s output, validate via `MetaSchema.validate!/1`, write to
  `<dir>/meta.json`, return the rendered map.

  `scenario_block` is shallow-merged — keys it sets override base
  keys with the same name. The synthetic writer passes
  `%{"benchmarks" => [...], "otp_benchmarks" => [...]}`; the XMPP
  writer passes `%{"xmpp" => %{...}, "applications" => [...]}`.
  """
  @spec write(Path.t(), RunContext.t(), map(), keyword()) :: map()
  def write(dir, %RunContext{} = rc, scenario_block, opts \\ []) when is_map(scenario_block) do
    meta = base(rc, opts) |> Map.merge(scenario_block)
    :ok = MetaSchema.validate!(meta)
    File.write!(Path.join(dir, "meta.json"), Jason.encode_to_iodata!(meta))
    meta
  end
end
