# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule OtpBenchmarks.MixProject do
  @moduledoc """
  BEAM-internal benchmark suite (phash2, ETS, maps, estone, Mnesia
  TPC-B, …). Sibling app to `apps/awfy/`; see
  `PLAN/EXTENDED_BENCH_PLAN.md` for the design.

  Held in a separate app from AWFY for two reasons:

    * **Licensing.** The AWFY suite is MIT (Stefan Marr's upstream).
      The OTP benchmarks here are ports of OTP source which is
      Apache-2.0. Different `apps/<name>/` directories make the
      license boundary obvious without relying on per-file SPDX
      vigilance inside one mixed tree.
    * **Drift.** AWFY's constraints (cross-language compute, fixed
      inner-iter loop, verify_result) and OTP-suite constraints
      (BIF/NIF dispatch, scenario inputs, optional setup/teardown
      for ETS/Mnesia state) evolve independently.

  Same shape as `apps/awfy/`: no runtime deps, low Elixir floor so
  the per-target build path can compile this with whichever Elixir
  is compatible with the target OTP, all benchmark sources under
  `lib/`. Anything that needs Benchee / Jason / orchestration
  belongs in the runner project at the repo root, not here.
  """
  use Mix.Project

  def project do
    [
      app: :otp_benchmarks,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: ["lib"],
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
