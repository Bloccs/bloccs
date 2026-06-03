defmodule Events.Nodes.Deadletter do
  @moduledoc """
  Records an unknown-type event in the `deadletter` table so nothing is silently
  dropped.
  """

  use Bloccs.Node, manifest: "../../nodes/deadletter.bloccs"

  alias Bloccs.Effects.DB

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(event, _ctx), do: {:ok, event}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(event, ctx) do
    {:ok, row} =
      DB.insert(ctx.effects.db, :deadletter,
        event_id: event.id,
        type: event.type
      )

    {:emit, :recorded, %{id: row[:id], event_id: event.id, type: event.type}}
  end
end
