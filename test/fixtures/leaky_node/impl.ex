defmodule Bloccs.Test.LeakyNode do
  @moduledoc """
  Fixture for `Bloccs.NodeMacroEffectCheckTest`.

  Declares only `http` in its manifest but the `execute/2` body deliberately
  references `ctx.effects.db.insert/3` and `ctx.effects.random.int/2`.
  Compiling this module should emit `IO.warn`s for both undeclared axes.
  Never `use`d outside the dedicated test.
  """

  use Bloccs.Node, manifest: "manifest.bloccs"

  def transform(payload, _ctx), do: {:ok, payload}

  def execute(payload, ctx) do
    # Declared:
    _ = ctx.effects.http
    # Undeclared — should trigger AST warnings:
    _ = ctx.effects.db.insert(:t, k: 1)
    _ = ctx.effects.random.int(10)

    {:emit, :out_a, payload}
  end
end
