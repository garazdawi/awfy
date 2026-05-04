# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

defmodule Awfy.MixProject do
  use Mix.Project

  def project do
    [
      app: :awfy,
      version: "0.1.0",
      # Lowered to ~> 1.14 so we can build against older OTP majors —
      # Elixir 1.14.5 ships `elixir-otp-23.zip` and runs on OTP 23+.
      # Bump back if we start using post-1.14 syntax (e.g. `Range.step`).
      elixir: "~> 1.14",
      erlc_paths: ["src"],
      erlc_options: [:debug_info, {:i, ~c"include"}],
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:benchee, "~> 1.5", only: [:dev, :test], runtime: false},
      # OTP's `:json` module is OTP-27+; we measure against OTP 26 too.
      {:jason, "~> 1.4"}
    ]
  end
end
