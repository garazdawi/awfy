# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.MixProject do
  @moduledoc """
  AWFY benchmark suite (Stefan Marr's *Are We Fast Yet* port).

  This app holds only the benchmark sources — Erlang in `src/`,
  Elixir in `lib/awfy/benchmarks/`, with shared helpers in
  `lib/awfy/`. It declares **no runtime dependencies** so the same
  source tree can be compiled by any OTP/Elixir combination the
  runner asks for: from the host environment via `mix compile` (the
  default path-dep workflow), and from the per-target build path
  used to benchmark older OTP releases.

  Keep `elixir:` low and the dep list empty here. Anything that
  needs Jason / Benchee / Jason / etc. belongs in `apps/runner/`
  (or wherever the orchestration lives), not in the benchmark suite.
  """
  use Mix.Project

  def project do
    [
      app: :awfy,
      version: "0.1.0",
      # ~> 1.9 floor matches apps/otp_benchmarks/ — the legacy
      # bundle path compiles this app under the target Elixir
      # (1.9.4 for OTP 20, 1.11.4 for OTP 21, …, see
      # bin/elixir-for-otp.sh). Anything that needs a newer
      # Elixir feature has to move to apps/runner/ or be guarded
      # on Code.ensure_loaded?, otherwise the Elixir-side
      # benchmarks silently disappear from legacy legs.
      elixir: "~> 1.9",
      erlc_paths: ["src"],
      erlc_options: [:debug_info],
      elixirc_paths: ["lib"],
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
