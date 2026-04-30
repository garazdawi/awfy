defmodule Awfy.MixProject do
  use Mix.Project

  def project do
    [
      app: :awfy,
      version: "0.1.0",
      elixir: "~> 1.16",
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
    []
  end
end
