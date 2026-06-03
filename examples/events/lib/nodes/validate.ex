defmodule Events.Nodes.Validate do
  @moduledoc """
  A purely-functional gate: an event with an empty payload is rejected in the
  pure core, so no effect node downstream ever runs for it. Declares no effects.
  """

  use Bloccs.Node, manifest: "../../nodes/validate.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
  def transform(event, _ctx) do
    if map_size(event.payload) > 0 do
      {:ok, event}
    else
      {:error, :empty_payload}
    end
  end

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(event, _ctx), do: {:emit, :valid, event}
end
