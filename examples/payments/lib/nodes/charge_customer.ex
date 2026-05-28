defmodule Payments.Nodes.ChargeCustomer do
  @moduledoc """
  The charge_customer node — verbatim shape from research/01.

  Pure core validates the request and builds the intent. Effect shell makes
  the (mocked) HTTP call and persists to the (mocked) DB. Only effects
  declared in `[effects]` are reachable.
  """

  use Bloccs.Node, manifest: "../../nodes/charge_customer.bloccs"

  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP
  alias Bloccs.Effects.DB.Mock, as: MockDB

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
  def transform(%{} = req, _ctx) do
    cond do
      not is_integer(req[:amount_cents]) or req[:amount_cents] <= 0 ->
        {:error, :invalid_amount}

      not is_binary(req[:currency]) ->
        {:error, :invalid_currency}

      not is_binary(req[:customer_id]) ->
        {:error, :invalid_customer}

      true ->
        {:ok,
         %{
           amount: req.amount_cents,
           currency: req.currency,
           customer: req.customer_id,
           idempotency_key: "#{req.customer_id}:#{req.request_id}"
         }}
    end
  end

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()} | {:error, term()}
  def execute(intent, ctx) do
    case MockHTTP.post(ctx.effects.http, "https://api.stripe.com/v1/charges", intent) do
      {:ok, %{"id" => stripe_id, "status" => "succeeded"}} ->
        {:ok, _row} =
          MockDB.insert(ctx.effects.db, :charges,
            customer_id: intent.customer,
            stripe_id: stripe_id,
            amount_cents: intent.amount
          )

        {:emit, :charge_completed,
         %{
           customer_id: intent.customer,
           stripe_id: stripe_id,
           amount_cents: intent.amount
         }}

      {:ok, %{"status" => status}} ->
        {:emit, :charge_failed,
         %{customer_id: intent.customer, reason: "stripe_status:#{status}"}}

      {:error, reason} ->
        {:emit, :charge_failed,
         %{customer_id: intent.customer, reason: inspect(reason)}}
    end
  end
end
