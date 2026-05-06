# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule AwfyRunner.MixProject do
  @moduledoc """
  Top-level mix project for the AWFY benchmark runner.

  This project contains the orchestration:
    * `Mix.Tasks.Awfy.{Measure,Compare,Diff,Fill,Preflight,Benchee}`
    * Per-run helpers under `lib/awfy/{benchee_runner,peer_runner,…}`
    * Plain-Erlang target harness under `src_target/` (compiled
      separately by each target OTP, not included here).

  Benchmark suites live under `apps/<name>/`, each with its own
  minimal `mix.exs`. Add a new suite by `path:`-depending on it
  here — the suite app declares its own benchmarks via the module
  the runner discovers (currently `Awfy.benchmarks/0`; future
  groups expose a similar list).

  We deliberately do *not* use a Mix umbrella: each app is
  independently compilable, including with a different
  Erlang/Elixir than the runner is using. That's needed for the
  cross-OTP target path where the suite is compiled by an old
  OTP's `erlc` while the runner orchestrates from the host.
  """
  use Mix.Project

  def project do
    [
      app: :awfy_runner,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      # Mix consolidates protocols in :prod by default and skips it in
      # :dev/:test. We run benchmarks under :dev (Benchee is a dev-only
      # dep), where unconsolidated protocols add overhead inside hot
      # paths like Enumerable / Inspect — Benchee warns about this and
      # it's a real source of measurement noise. Force consolidation in
      # every env so the numbers are comparable to a release build.
      consolidate_protocols: true,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Benchmark suites — each is a standalone app at apps/<name>/
      # depended on via its on-disk path. Compilation happens
      # transitively when this project compiles.
      {:awfy, path: "apps/awfy"},

      # Orchestration deps — these stay at the runner level so suites
      # don't pick up unwanted runtime libs.
      {:benchee, "~> 1.5", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"}
    ]
  end

  # `mix precommit` runs locally everything CI runs — compiler as
  # error, REUSE, shellcheck, ESLint/stylelint and Vitest on
  # priv/dashboard.{js,css}, plus mix-test in any sibling app under
  # apps/ that ships a test/ tree. Faster than waiting for the GHA
  # round-trip and catches the same issues. Requires:
  #   * `reuse` on $PATH         — pip install reuse
  #   * `shellcheck` on $PATH    — brew install shellcheck
  #   * `npm install` once       — populates node_modules/ for the
  #                                JS/CSS linters and Vitest
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "cmd reuse lint --quiet",
        # mix `cmd` runs execvp without a shell — wrap in `sh -c` so
        # the bin/*.sh glob expands.
        ~s|cmd sh -c 'shellcheck bin/*.sh'|,
        "cmd npm run lint --silent",
        "cmd npm test --silent",
        # Sibling apps under apps/ aren't pulled into the root
        # project (apps/awfy_target_runner is intentionally not a
        # path-dep — see PLAN/TARGET_ELIXIR_RUNNER_PLAN.md decision
        # #10). Run `mix test` in each that ships a test/ tree, so
        # local pre-commit checks stay symmetric with CI.
        &test_apps_with_tests/1
      ]
    ]
  end

  defp test_apps_with_tests(_args) do
    Path.wildcard("apps/*/test")
    |> Enum.map(&Path.dirname/1)
    |> Enum.sort()
    |> Enum.each(fn app_dir ->
      Mix.shell().info("==> mix test (#{app_dir})")

      {_out, status} =
        System.cmd("mix", ["test"], cd: app_dir, into: IO.stream(:stdio, :line))

      if status != 0 do
        Mix.raise("mix test failed in #{app_dir}")
      end
    end)
  end
end
