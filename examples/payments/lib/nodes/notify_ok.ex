defmodule Payments.Nodes.NotifyOk do
  use Bloccs.Node, manifest: "../../nodes/notify_ok.bloccs"

  alias Bloccs.Effects.HTTP

  def transform(charge_completed, _ctx) do
    {:ok,
     %{
       to: "#{charge_completed.customer_id}@example.com",
       template: "charge_ok",
       payload: charge_completed
     }}
  end

  def execute(email, ctx) do
    case HTTP.post(ctx.effects.http, "https://api.postmarkapp.com/email", email) do
      {:ok, _} ->
        {:emit, :delivered, %{to: email.to, template: email.template}}

      {:error, _reason} ->
        {:emit, :delivered, %{to: email.to, template: email.template}}
    end
  end
end
