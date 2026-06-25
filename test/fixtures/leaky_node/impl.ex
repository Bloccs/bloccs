defmodule Bloccs.Test.LeakyNode do
  @moduledoc """
  Fixture for `Bloccs.NodeMacroEffectCheckTest`.

  Declares only `http` in its manifest but the `execute/2` body deliberately
  routes the undeclared `db` and `random` axes through the facade
  (`DB.insert(ctx.effects.db, …)`, `Random.int(ctx.effects.random, …)`).
  Compiling this module should emit `IO.warn`s for both undeclared axes — the
  facade calls keep `Bloccs.Node.EffectLint` happy while the `ctx.effects.<axis>`
  chain still trips the undeclared-axis walker. Never `use`d outside the test.
  """

  use Bloccs.Node, manifest: "manifest.bloccs"

  alias Bloccs.Effects.{DB, Random}

  def transform(payload, _ctx), do: {:ok, payload}

  def execute(payload, ctx) do
    # Declared:
    _ = ctx.effects.http
    # Undeclared — should trigger AST warnings via the ctx.effects.<axis> chain:
    _ = DB.insert(ctx.effects.db, :t, k: 1)
    _ = Random.int(ctx.effects.random, 10)

    {:emit, :out_a, payload}
  end
end
