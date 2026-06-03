defmodule Events.Nodes.Notify do
  @moduledoc """
  Notifies a downstream webhook over HTTP that a known event was processed.
  Delivery failure still emits (with status "failed") rather than crashing the
  pipeline — a real app might route failures to a retry node instead.
  """

  use Bloccs.Node, manifest: "../../nodes/notify.bloccs"

  alias Bloccs.Effects.HTTP

  @hook_url "http://hooks.local/notify"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(event, _ctx), do: {:ok, event}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(event, ctx) do
    status =
      case HTTP.post(ctx.effects.http, @hook_url, %{id: event.id, type: event.type}) do
        {:ok, _} -> "sent"
        {:error, _} -> "failed"
      end

    {:emit, :notified, %{id: event.id, status: status}}
  end
end
