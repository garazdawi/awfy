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

  The Elixir floor is `~> 1.9` to cover the legacy bundle path's
  target Elixirs (1.9.4 for OTP 20, 1.11.4 for OTP 21, 1.13.4 for
  OTP 22, 1.14.5 for OTP 23). `bin/build-target-bundle.sh` mix-
  compiles this app under whichever target Elixir matches the
  target OTP, so the floor is load-bearing — bumping it narrows
  the OTP range that can produce OtpBenchmarks data.
  """
  use Mix.Project

  def project do
    [
      app: :otp_benchmarks,
      version: "0.1.0",
      elixir: "~> 1.9",
      elixirc_paths: ["lib"],
      # vendor/ holds the upstream estone_SUITE.erl (verbatim copy
      # from erlang/otp's erts/emulator/test/) — see vendor/README.md.
      # -DPGO makes the suite self-contained (drops common_test);
      # +nowarn_deprecated_function silences erlang:now/0 (estone
      # still uses it for timing on get_cpu_speed). The .erl is
      # under vendor/ not src/ so it stays visually separate from
      # AWFY-authored code.
      erlc_paths: ["vendor"],
      erlc_options: [
        {:d, :PGO},
        :nowarn_deprecated_function,
        :nowarn_unused_function,
        :nowarn_unused_vars
      ],
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    # `:mnesia` is loaded for the Mnesia TPC-B families'
    # `:mnesia.start/0` setup; it has to be in the extra-apps list
    # so the BEAM finds it without an explicit
    # `Application.ensure_all_started/1`. Loading mnesia at app
    # boot is cheap when no schema is configured (no on-disk dirs
    # touched until create_schema is called).
    [extra_applications: [:logger, :mnesia]]
  end
end
