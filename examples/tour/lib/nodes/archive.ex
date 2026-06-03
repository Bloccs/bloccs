defmodule Tour.Nodes.Archive do
  @moduledoc "Rung 3 sink. Pure — emits an `archived` receipt."

  use Bloccs.Node, manifest: "../../nodes/archive.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(message, _ctx), do: {:ok, message}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(message, _ctx), do: {:emit, :archived, %{id: message.id, outcome: "archived"}}
end
