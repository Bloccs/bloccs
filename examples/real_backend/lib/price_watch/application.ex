defmodule PriceWatch.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:price_watch, :api_port, 4011)

    children = [
      PriceWatch.Repo,
      {Bandit, plug: PriceWatch.StubAPI, port: port}
    ]

    opts = [strategy: :one_for_one, name: PriceWatch.Supervisor]

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      ensure_schema!()
      PriceWatch.Schemas.register()
      {:ok, sup}
    end
  end

  # Create the quotes table on boot (idempotent) so the DB.Ecto adapter has
  # somewhere to insert. A real app would use migrations.
  defp ensure_schema! do
    PriceWatch.Repo.query!("""
    CREATE TABLE IF NOT EXISTS quotes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id TEXT,
      symbol TEXT NOT NULL,
      price INTEGER NOT NULL,
      recorded_at TEXT NOT NULL
    )
    """)
  end
end
