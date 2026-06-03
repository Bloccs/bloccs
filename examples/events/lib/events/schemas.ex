defmodule Events.Schemas do
  @moduledoc """
  Versioned port schemas for the `events` network. Registered before any message
  flows (by the demo task, or by the integration test setup).
  """

  alias Bloccs.Schema

  def register do
    Schema.register("RawEvent@1",
      id: :string,
      type: :string,
      payload: :map
    )

    Schema.register("EnrichedEvent@1",
      id: :string,
      type: :string,
      payload: :map,
      enrichment: :map
    )

    Schema.register("StoredEvent@1",
      id: :integer,
      event_id: :string,
      type: :string
    )

    Schema.register("Notified@1",
      id: :string,
      status: :string
    )

    :ok
  end
end
