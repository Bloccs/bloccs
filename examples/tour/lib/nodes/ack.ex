defmodule Tour.Nodes.Ack do
  @moduledoc "Rung 3 sink. Pure — emits an `acked` receipt."

  use Bloccs.Node, manifest: "../../nodes/ack.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(message, _ctx), do: {:ok, message}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(message, _ctx), do: {:emit, :acked, %{id: message.id, outcome: "acked"}}
end
