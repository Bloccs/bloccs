defmodule Tour.Schemas do
  @moduledoc "Versioned port schemas for all four tour rungs. Registered on app start."

  alias Bloccs.Schema

  def register do
    # Rung 1 — hello
    Schema.register("Name@1", name: :string)
    Schema.register("Greeting@1", message: :string)

    # Rung 2 — pipeline
    Schema.register("WordRequest@1", word: :string)
    Schema.register("Definition@1", word: :string, definition: :string)

    # Rung 3 — branching
    Schema.register("Message@1", id: :string, text: :string)
    Schema.register("Receipt@1", id: :string, outcome: :string)

    # Rung 4 — filter + split
    Schema.register("Audit@1", id: :string, note: :string)

    :ok
  end
end
