defmodule PriceWatch.MixProject do
  use Mix.Project

  # A standalone example app that consumes bloccs as a path dependency — exactly
  # how a real project would — and supplies its own Ecto/SQLite stack. It runs a
  # bloccs network end-to-end against REAL backends with zero external services:
  # a local Bandit stub stands in for the "quote API" (real HTTP over a socket),
  # and ecto_sqlite3 persists results to a local file DB.

  def project do
    [
      app: :price_watch,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PriceWatch.Application, []}
    ]
  end

  defp deps do
    [
      {:bloccs, path: "../.."},
      # bloccs marks :req optional — a consumer using the real HTTP.Req backend
      # brings it themselves (just as we bring ecto_sqlite3 for DB.Ecto).
      {:req, "~> 0.5"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"}
    ]
  end
end
