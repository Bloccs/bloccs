defmodule Events.Nodes.Ingest do
  @moduledoc """
  The network's entry point. Normalizes an inbound webhook event into a stable
  shape (`%{id, type, payload}`, type lower-cased) so every downstream node can
  rely on atom keys. A missing id or type fails in the pure core.
  """

  use Bloccs.Node, manifest: "../../nodes/ingest.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
  def transform(raw, _ctx) do
    id = raw[:id] || raw["id"]
    type = raw[:type] || raw["type"]
    payload = raw[:payload] || raw["payload"]

    if is_binary(id) and is_binary(type) and is_map(payload) do
      {:ok, %{id: id, type: String.downcase(type), payload: payload}}
    else
      {:error, :missing_id_or_type}
    end
  end

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(event, _ctx), do: {:emit, :event, event}
end
