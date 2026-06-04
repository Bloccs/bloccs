defmodule Tour.Nodes.AuditSink do
  @moduledoc "Rung 4 sink. Pure — emits a `logged` receipt for an audit entry."

  use Bloccs.Node, manifest: "../../nodes/audit_sink.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(entry, _ctx), do: {:ok, entry}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(entry, _ctx), do: {:emit, :logged, %{id: entry.id, outcome: "audited"}}
end
