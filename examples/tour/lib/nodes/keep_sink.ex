defmodule Tour.Nodes.KeepSink do
  @moduledoc "Rung 4 sink. Pure — emits a `stored` receipt for a kept message."

  use Bloccs.Node, manifest: "../../nodes/keep_sink.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(message, _ctx), do: {:ok, message}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(message, _ctx), do: {:emit, :stored, %{id: message.id, outcome: "stored"}}
end
