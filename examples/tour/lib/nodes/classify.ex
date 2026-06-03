defmodule Tour.Nodes.Classify do
  @moduledoc """
  Rung 3. A router: short messages go out the `ok` port, long ones out `flagged`.
  The network wires `ok` to two sinks (fan-out) and `flagged` to a third. Pure.
  """

  use Bloccs.Node, manifest: "../../nodes/classify.bloccs"

  @max_ok_length 20

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(message, _ctx), do: {:ok, message}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(message, _ctx) do
    if String.length(message.text) <= @max_ok_length do
      {:emit, :ok, message}
    else
      {:emit, :flagged, message}
    end
  end
end
