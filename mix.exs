defmodule Bloccs.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      # Optional: only needed by the real HTTP backend (Bloccs.Effects.HTTP.Req).
      # The default is the mock; consumers add :req themselves to use HTTP.Req.
      {:req, "~> 0.5", optional: true},
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
        # Prove the library compiles cleanly even when optional deps (:req) are
        # absent — the official Library Guidelines recommendation.
        "compile --no-optional-deps --warnings-as-errors",
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
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs guides)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/concepts.md",
        "guides/getting-started.md",
        "guides/manifest-reference.md",
        "guides/effect-adapters.md",
        "guides/comparison.md",
        "guides/ARCHITECTURE.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r{guides/}
      ]
    ]
  end
end
