defmodule Bloccs.Test.LeakyNodeRenamed do
  @moduledoc """
  Fixture for `Bloccs.NodeMacroEffectCheckTest`.

  Same leak as `leaky_node`, but the context parameter is named `context`
  rather than `ctx` — the walker must match the `.effects.<axis>` chain on
  any variable name. Never `use`d outside the dedicated test.
  """

  use Bloccs.Node, manifest: "manifest.bloccs"

  def transform(payload, _context), do: {:ok, payload}

  def execute(payload, context) do
    # Undeclared — must trigger the AST warning despite the renamed param:
    _ = context.effects.db.insert(:t, k: 1)

    {:emit, :out_a, payload}
  end
end
