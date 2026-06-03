defmodule Tour.MixProject do
  use Mix.Project

  # A guided, three-rung tour of bloccs core concepts. It consumes bloccs as a
  # path dependency and runs entirely on the built-in mock effect backends — no
  # external services, no extra deps. Each rung is its own network + demo task:
  #
  #   mix tour.hello      — one pure node          (node, port, schema, the loop)
  #   mix tour.pipeline   — two nodes + one effect (edges, effect shell)
  #   mix tour.branching  — a router + fan-out     (branching, multiple out-ports)

  def project do
    [
      app: :tour,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Tour.Application, []}
    ]
  end

  defp deps do
    [
      {:bloccs, path: "../.."}
    ]
  end
end
