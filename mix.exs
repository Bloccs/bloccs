defmodule Bloccs.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/Bloccs/bloccs"

  def project do
    [
      app: :bloccs,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      preferred_cli_env: [check: :test],
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ex_ast],
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Bloccs.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "examples/payments/lib"]
  defp elixirc_paths(:dev), do: ["lib", "examples/payments/lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:toml, "~> 0.7"},
      {:broadway, "~> 1.1"},
      {:gen_stage, "~> 1.2"},
      {:telemetry, "~> 1.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:program_facts, "~> 0.2", only: :test, runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "A typed declarative IR for Agentic Computation Graphs (ACGs) that compiles to a Broadway supervision tree on the BEAM."
  end

  defp package do
    [
      maintainers: ["Allan MacGregor"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "https://bloccs.io"
      },
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
