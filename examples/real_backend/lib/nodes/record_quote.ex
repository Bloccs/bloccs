defmodule PriceWatch.Nodes.RecordQuote do
  @moduledoc """
  Persists a fetched quote to SQLite through the REAL `Bloccs.Effects.DB.Ecto`
  backend (schemaless `insert_all` into the `quotes` table). The declared
  `quotes:insert` scope is enforced by the capability layer. Idempotent on
  `request_id`, so a duplicate delivery is not written twice.
  """

  use Bloccs.Node, manifest: "../../nodes/record_quote.bloccs"

  alias Bloccs.Effects.{DB, Time}

  def transform(%{} = fetched, _ctx) do
    {:ok,
     %{
       symbol: fetched[:symbol] || fetched["symbol"],
       price: fetched[:price] || fetched["price"],
       request_id: fetched[:request_id] || fetched["request_id"]
     }}
  end

  def execute(%{symbol: symbol, price: price, request_id: request_id}, ctx) do
    recorded_at = ctx.effects.time |> Time.now() |> DateTime.to_iso8601()

    {:ok, _row} =
      DB.insert(ctx.effects.db, :quotes,
        request_id: request_id,
        symbol: symbol,
        price: price,
        recorded_at: recorded_at
      )

    {:emit, :recorded, %{symbol: symbol, price: price}}
  end
end
