defmodule Payments.Nodes.Ledger do
  use Bloccs.Node, manifest: "../../nodes/ledger.bloccs"

  alias Bloccs.Effects.DB

  def transform(charge_completed, _ctx) do
    {:ok,
     %{
       event_type: "charge_completed",
       payload: %{
         customer_id: charge_completed.customer_id,
         stripe_id: charge_completed.stripe_id,
         amount_cents: charge_completed.amount_cents
       }
     }}
  end

  def execute(event, ctx) do
    {:ok, _row} =
      DB.insert(ctx.effects.db, :ledger,
        event_type: event.event_type,
        payload: event.payload
      )

    {:emit, :committed, event}
  end
end
