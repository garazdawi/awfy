defmodule Benchee.Mixfile do
  use Mix.Project

  @source_url "https://github.com/bencheeorg/benchee"
  @version "1.5.0"

  def project do
    [
      app: :benchee,
      version: @version,
      elixir: "~> 1.6",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: true,
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      test_ignore_filters: [~r/test\/fixtures/],
      dialyzer: [
        flags: [:underspecs],
        plt_file: {:no_warn, "tools/plts/benchee.plt"},
        plt_add_apps: [:table]
      ],
      name: "Benchee",
      description: """
      Versatile (micro) benchmarking that is extensible. Get statistics such as:
      average, iterations per second, standard deviation and the median.
      """
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.travis": :test,
        "safe_coveralls.travis": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "mix"]
  defp elixirc_paths(_), do: ["lib"]

  # Stripped of dev/test/docs deps per
  # PLAN/TARGET_ELIXIR_RUNNER_PLAN.md Appendix A. Mix 1.9 walks the
  # full transitive `deps()` list of every dep regardless of MIX_ENV
  # and `only:`, so dev/test entries trigger Hex registry lookups
  # which cannot succeed when target OTP is built `--without-ssl`.
  # The conditional `:table` branch is also dropped — `:table` is
  # unused on our codepath and re-introduces the same SCM-lookup
  # problem.
  defp deps do
    [
      {:deep_merge, path: "../deep_merge"},
      {:statistex, path: "../statistex"}
    ]
  end

  defp package do
    [
      maintainers: ["Tobias Pfeiffer", "Devon Estes"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "https://hexdocs.pm/benchee/changelog.html",
        "GitHub" => @source_url,
        "Blog posts" => "https://pragtob.wordpress.com/tag/benchee/"
      }
    ]
  end

  defp docs do
    [
      extras: [
        "CHANGELOG.md": [],
        "LICENSE.md": [title: "License"],
        "README.md": [title: "Readme"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: @version,
      api_reference: false,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end
