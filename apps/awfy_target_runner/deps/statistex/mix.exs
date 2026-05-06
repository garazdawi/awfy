defmodule Statistex.MixProject do
  use Mix.Project

  @version "1.1.0"
  def project do
    [
      app: :statistex,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        source_ref: @version,
        extras: ["README.md"],
        main: "readme"
      ],
      package: package(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.travis": :test,
        "safe_coveralls.travis": :test
      ],
      dialyzer: [
        flags: [:unmatched_returns, :error_handling, :underspecs],
        plt_file: {:no_warn, "tools/plts/benchee.plt"}
      ],
      name: "Statistex",
      source_url: "https://github.com/bencheeorg/statistex",
      description: """
      Calculate statistics on data sets, reusing previously calculated values or just all metrics at once. Part of the benchee library family.
      """
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  # Stripped of dev/test/docs deps per
  # PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A. See apps/awfy_target_runner/deps/benchee
  # for the full rationale.
  defp deps do
    []
  end

  defp package do
    [
      maintainers: ["Tobias Pfeiffer"],
      licenses: ["MIT"],
      links: %{
        "github" => "https://github.com/bencheeorg/statistex"
      }
    ]
  end
end
