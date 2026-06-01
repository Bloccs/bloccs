defmodule Payments.Nodes.NotifyFail do
  use Bloccs.Node, manifest: "../../nodes/notify_fail.bloccs"

  alias Bloccs.Effects.HTTP

  def transform(charge_failed, _ctx) do
    {:ok,
     %{
       to: "#{charge_failed.customer_id}@example.com",
       template: "charge_fail",
       payload: charge_failed
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
