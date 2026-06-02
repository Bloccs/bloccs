defmodule PriceWatch.Nodes.FetchQuote do
  @moduledoc """
  Fetches a price for the requested symbol from the quote API over REAL HTTP
  (the `Bloccs.Effects.HTTP.Req` backend, selected via config). The allowlist in
  the manifest (`localhost`) is enforced before any request leaves the VM.
  """

  use Bloccs.Node, manifest: "../../nodes/fetch_quote.bloccs"

  alias Bloccs.Effects.HTTP

  def transform(req, _ctx) do
    symbol = req[:symbol] || req["symbol"]
    request_id = req[:request_id] || req["request_id"]

    if is_binary(symbol) and symbol != "" do
      {:ok, %{symbol: symbol, request_id: request_id}}
    else
      {:error, :invalid_symbol}
    end
  end

  def execute(%{symbol: symbol, request_id: request_id}, ctx) do
    url = "#{base_url()}/quote/#{symbol}"

    case HTTP.get(ctx.effects.http, url) do
      {:ok, %{"price" => price}} when is_integer(price) ->
        {:emit, :quote_fetched, %{symbol: symbol, price: price, request_id: request_id}}

      {:ok, other} ->
        {:error, {:unexpected_quote_body, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_url do
    port = Application.get_env(:price_watch, :api_port, 4011)
    "http://localhost:#{port}"
  end
end
