defmodule PriceWatch.StubAPI do
  @moduledoc """
  A tiny local HTTP API standing in for an external quote provider, so the
  example does real HTTP (real sockets, real JSON, real Req) with zero external
  services. Prices are a deterministic function of the symbol.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/quote/:symbol" do
    price = :erlang.phash2(symbol, 900) + 100

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"symbol" => symbol, "price" => price}))
  end

  match _ do
    send_resp(conn, 404, ~s({"error":"not found"}))
  end
end
