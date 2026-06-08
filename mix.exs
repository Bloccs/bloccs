defmodule Bloccs.MixProject do
  use Mix.Project

  @version "0.8.0"
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

  defp elixirc_paths(:test), do: ["lib", "test/support", "examples/events/lib"]
  defp elixirc_paths(:dev), do: ["lib", "examples/events/lib"]
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
    "Typed, supervised dataflow on the BEAM: describe a graph of processing stages " <>
      "as TOML and compile it to a Broadway supervision tree, with schema-checked " <>
      "edges and capability-scoped effects."
  end

  defp package do
    [
      maintainers: ["Allan MacGregor"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "https://bloccs.io"
      },
      # Ship the rendered PNGs (the README + hexdocs use them); the editable
      # source SVGs stay in the repo but are not packaged.
      files:
        ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE .formatter.exs guides assets/*.png)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/bloccs-mark.png",
      source_url: @source_url,
      source_ref: "v#{@version}",
      assets: %{"assets" => "assets"},
      # Keep the glyph thumbnails in the Primitives table small (the source PNGs
      # are 200px; only that table puts images in cells).
      before_closing_head_tag: fn _format ->
        ~s(<style>td img{max-height:2.4em;width:auto;vertical-align:middle}</style>)
      end,
      # Document only the library's own modules. Examples (`examples/*/lib`) are
      # compiled in dev/test via elixirc_paths but are NOT in the Hex package, so
      # this keeps local `mix docs` equivalent to the published docs.
      filter_modules: fn mod, _meta ->
        name = inspect(mod)
        String.starts_with?(name, "Bloccs") or String.starts_with?(name, "Mix.Tasks.Bloccs")
      end,
      extras: [
        {"README.md", [title: "bloccs"]},
        "guides/concepts.md",
        "guides/getting-started.md",
        "guides/primitives.md",
        "guides/request-response.md",
        "guides/manifest-reference.md",
        "guides/effect-adapters.md",
        "guides/comparison.md",
        "guides/ARCHITECTURE.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r{guides/}
      ],
      nest_modules_by_prefix: [Bloccs.Effects, Bloccs.Manifest, Bloccs.Compiler],
      groups_for_modules: [
        "Manifests & parsing": [Bloccs.Parser, Bloccs.Schema, ~r/^Bloccs\.Manifest/],
        Validation: [Bloccs.Validator, Bloccs.Node],
        Compilation: [~r/^Bloccs\.Compiler/],
        Runtime: [
          Bloccs.Runtime,
          Bloccs.Router,
          Bloccs.Producer,
          Bloccs.Join,
          Bloccs.Retry,
          Bloccs.Idempotency,
          Bloccs.Context,
          Bloccs.Pipeline
        ],
        "Request/response": [Bloccs.Collector, Bloccs.EffectError],
        Effects: [~r/^Bloccs\.Effects/],
        Observability: [
          Bloccs.Telemetry,
          Bloccs.Trace,
          Bloccs.Coverage,
          Bloccs.Introspect,
          Bloccs.Introspect.Network,
          Bloccs.Discovery,
          Bloccs.Inspect
        ],
        "Mix tasks": [~r/^Mix\.Tasks\.Bloccs/]
      ]
    ]
  end
end
