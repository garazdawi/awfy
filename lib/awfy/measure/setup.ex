# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.Measure.Setup do
  @moduledoc """
  Shared scaffolding for every `mix awfy.measure*` task: build a
  `RunContext`, compute the run-dir name, handle the
  exists-but-no-clobber-set dance, ensure the dir exists. Before
  this module existed each task open-coded the same paragraph,
  which is the kind of mechanical duplication that drifts when a
  future fix (better dir-naming, atomic rename, …) lands in one
  task and silently doesn't land in the other.

  Two public functions:

  * `prepare/2(opts, scenario_tag)` — builds the RunContext, the
    run-dir path, and ensures the dir exists. Returns
    `{:ok, run_ctx, dir}`. Raises via `Mix.raise/1` when
    `--no-clobber` is set and the dir already exists; warns and
    re-creates otherwise.

  * `out_root/1(opts)` — defaults `opts[:out]` to `"results"`. Tiny
    helper but it's worth pulling out so the default lives in one
    place (we'd flip it to `"_pages"` someday in CI, and there
    should be a single line to change).

  PLAN/INFRA_REFACTOR.md § 6.
  """

  alias Awfy.RunContext
  alias Awfy.Measure.Helpers

  @doc """
  Resolve `opts[:out]` or fall back to `"results"`.
  """
  @spec out_root(keyword()) :: String.t()
  def out_root(opts), do: opts[:out] || "results"

  @doc """
  Build a `RunContext` + run-dir path + ensure the dir exists.

  Honours `opts[:no_clobber]` — when set, an existing dir raises
  via `Mix.raise/1`. Without it, an existing dir is wiped with a
  `[warn]` info message and rebuilt. The wipe behaviour matches the
  pre-refactor measure tasks; the dashboard's run-discovery is
  Path.wildcard-based so leaving stale .benchee files behind would
  mix incompatible scenario sets.

  Returns `{:ok, run_ctx, dir}`.
  """
  @spec prepare(keyword(), RunContext.scenario_tag()) :: {:ok, RunContext.t(), String.t()}
  def prepare(opts, scenario_tag) when is_atom(scenario_tag) do
    run_ctx = RunContext.new(scenario: scenario_tag, label: opts[:label])

    dir =
      Helpers.run_dir(
        out_root(opts),
        run_ctx.label,
        DateTime.utc_now(),
        run_ctx.otp_release,
        run_ctx.elixir_version
      )

    if File.exists?(dir) do
      if opts[:no_clobber] do
        Mix.raise("results dir #{dir} exists and --no-clobber set")
      else
        Mix.shell().info("[warn] overwriting existing run dir: #{dir}")
        File.rm_rf!(dir)
      end
    end

    File.mkdir_p!(dir)

    {:ok, run_ctx, dir}
  end
end
