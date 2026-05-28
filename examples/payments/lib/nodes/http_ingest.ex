defmodule Payments.Nodes.HttpIngest do
  @moduledoc """
  Source node — turns an HTTP-ish request into a typed ChargeRequest.
  Pure core only; no effects declared.
  """

  use Bloccs.Node, manifest: "../../nodes/http_ingest.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(%{} = req, _ctx) do
    body = Map.get(req, :body, %{})

    charge_request = %{
      customer_id: Map.get(body, "customer_id") || Map.get(body, :customer_id),
      amount_cents: Map.get(body, "amount_cents") || Map.get(body, :amount_cents),
      currency: Map.get(body, "currency") || Map.get(body, :currency),
      request_id: Map.get(body, "request_id") || Map.get(body, :request_id)
    }

    {:ok, charge_request}
  end

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(charge_request, _ctx) do
    {:emit, :charge_request, charge_request}
  end
end
