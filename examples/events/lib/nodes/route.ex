defmodule Events.Nodes.Route do
  @moduledoc """
  Branches on event type. Known types are emitted on the `known` out-port (which
  the network fans out to persist + notify); everything else goes to `unknown`
  (dead-lettered). Pure — the routing decision touches nothing.
  """

  use Bloccs.Node, manifest: "../../nodes/route.bloccs"

  @known ~w(order.created order.updated user.created)

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(event, _ctx), do: {:ok, event}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(event, _ctx) do
    if event.type in @known do
      {:emit, :known, event}
    else
      {:emit, :unknown, event}
    end
  end
end
