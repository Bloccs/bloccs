defmodule PriceWatch.Schemas do
  @moduledoc """
  Versioned port schemas for the price_watch network. Registered on app start.
  """

  alias Bloccs.Schema

  def register do
    Schema.register("QuoteRequest@1",
      symbol: :string,
      request_id: :string
    )

    Schema.register("QuoteFetched@1",
      symbol: :string,
      price: :integer,
      request_id: :string
    )

    Schema.register("QuoteRecorded@1",
      id: :integer,
      symbol: :string,
      price: :integer
    )

    :ok
  end
end
