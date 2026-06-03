defmodule Events.Nodes.Persist do
  @moduledoc """
  Persists a known event to the `events` table via the DB effect, then emits the
  stored row (echoing the DB-generated id).
  """

  use Bloccs.Node, manifest: "../../nodes/persist.bloccs"

  alias Bloccs.Effects.DB

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(event, _ctx), do: {:ok, event}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(event, ctx) do
    {:ok, row} =
      DB.insert(ctx.effects.db, :events,
        event_id: event.id,
        type: event.type
      )

    {:emit, :stored, %{id: row[:id], event_id: event.id, type: event.type}}
  end
end
