defmodule DeepMerge.Mixfile do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :deep_merge,
      version: @version,
      elixir: "~> 1.6",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: [source_ref: @version],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.travis": :test
      ],
      package: package(),
      name: "deep_merge",
      source_url: "https://github.com/PragTob/deep_merge",
      dialyzer: [
        flags: [:unmatched_returns, :error_handling, :race_conditions, :underspecs],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ],
      description: """
      Deep (recursive) merging for maps, keyword lists and whatever else
      you may want via implementing a simple protocol.
      """
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    []
  end

  # Stripped of dev/test/docs deps per
  # PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A. See deps/benchee
  # for the full rationale.
  defp deps do
    []
  end

  defp package do
    [
      maintainers: ["Tobias Pfeiffer"],
      licenses: ["MIT"],
      links: %{
        "github" => "https://github.com/PragTob/deep_merge"
      }
    ]
  end
end
