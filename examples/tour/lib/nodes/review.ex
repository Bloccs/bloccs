defmodule Tour.Nodes.Review do
  @moduledoc "Rung 3 sink. Pure — emits a `queued` receipt."

  use Bloccs.Node, manifest: "../../nodes/review.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(message, _ctx), do: {:ok, message}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(message, _ctx), do: {:emit, :queued, %{id: message.id, outcome: "queued_for_review"}}
end
