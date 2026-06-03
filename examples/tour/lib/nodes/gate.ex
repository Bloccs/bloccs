defmodule Tour.Nodes.Gate do
  @moduledoc """
  Rung 4. A filter + split in one node.

  - **Filter:** a blank message is dropped — the shell returns `:drop`, so the
    message is consumed and emits nothing (a `[:bloccs, :node, :dropped]` event
    fires; nothing reaches the sinks).
  - **Split:** every other message is emitted to BOTH `kept` and `audit` in a
    single invocation, each with a distinct payload — `{:emit, [{port, payload},
    ...]}`.

  Pure.
  """

  use Bloccs.Node, manifest: "../../nodes/gate.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(message, _ctx), do: {:ok, message}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, [{atom(), map()}]} | :drop
  def execute(%{text: text} = message, _ctx) do
    if String.trim(text) == "" do
      :drop
    else
      audit = %{id: message.id, note: "#{String.length(text)} chars"}
      {:emit, [{:kept, message}, {:audit, audit}]}
    end
  end
end
