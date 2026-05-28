defmodule Payments.Schemas do
  @moduledoc """
  Versioned schemas for the payments sample network. Call `register/0` at app
  start to install them into `Bloccs.Schema`.
  """

  alias Bloccs.Schema

  def register do
    Schema.register("HttpRequest@1",
      method: :string,
      path: :string,
      body: :map
    )

    Schema.register("ChargeRequest@1",
      customer_id: :string,
      amount_cents: :integer,
      currency: :string,
      request_id: :string
    )

    Schema.register("ChargeCompleted@1",
      customer_id: :string,
      stripe_id: :string,
      amount_cents: :integer
    )

    Schema.register("ChargeFailed@1",
      customer_id: :string,
      reason: :string
    )

    Schema.register("EmailDelivered@1",
      to: :string,
      template: :string
    )

    Schema.register("LedgerEvent@1",
      event_type: :string,
      payload: :map
    )

    :ok
  end
end
