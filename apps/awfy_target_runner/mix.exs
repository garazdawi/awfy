# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.TargetRunner.MixProject do
  @moduledoc """
  Target-side Elixir runner for AWFY pre-OTP-24 measurements.

  Compiled into a self-contained bundle by `bin/build-target-bundle.sh`
  and shipped to a target OTP whose version pre-dates Elixir's
  setup-beam coverage. The host's `Awfy.Runner` (Phase 2) shells
  out to this bundle's `Awfy.TargetRunner.main/0` for each
  benchmark.

  Sibling app under `apps/`, NOT a path-dep of the root `mix.exs`.
  See PLAN/TARGET_ELIXIR_RUNNER_PLAN.md resolved decision #10.
  """
  use Mix.Project

  def project do
    [
      app: :awfy_target_runner,
      version: "0.1.0",
      # Lowest target Elixir we pin (OTP 20 → Elixir 1.9.4). The
      # sub-app and its vendored deps must compile under every
      # version in the OTP × Elixir matrix; 1.9 is the floor.
      elixir: "~> 1.9",
      build_path: "_build",
      config_path: "config/config.exs",
      deps_path: "deps",
      lockfile: "mix.lock",
      # Benchmarks run under :prod-equivalent semantics on the
      # target — protocols consolidated, embedded debug stripped.
      consolidate_protocols: true,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Vendored under deps/ — no Hex resolution, no SCM lookup. The
  # target OTP is built `--without-ssl` (Phase 0 default for OTP <
  # 24), so any path to the Hex registry would fail. See
  # apps/awfy_target_runner/deps/benchee/mix.exs and
  # PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A.
  defp deps do
    [
      {:benchee, path: "deps/benchee"},
      {:deep_merge, path: "deps/deep_merge"},
      {:statistex, path: "deps/statistex"}
    ]
  end
end
