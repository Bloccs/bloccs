defmodule Bloccs.NodeMacroEffectCheckTest do
  @moduledoc """
  Confirms the compile-time AST walker in `Bloccs.Node` actually fires when
  an `effect_shell` references `ctx.effects.<axis>` for an axis that the
  manifest's `[effects]` block does not declare.

  Closes audit gap #1 from `docs/v0.1-audit.md` — the walker was
  real-but-unverified before this test landed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @fixture_path Path.expand("../fixtures/leaky_node/impl.ex", __DIR__)

  test "AST walker warns on undeclared effect axes used by effect_shell" do
    captured =
      capture_io(:stderr, fn ->
        Code.compile_file(@fixture_path)
      end)

    assert captured =~ "effect :db used in effect_shell"
    assert captured =~ "effect :random used in effect_shell"
    refute captured =~ "effect :http used in effect_shell"
  end

  test "warning includes the declared-effects list for context" do
    captured =
      capture_io(:stderr, fn ->
        Code.compile_file(@fixture_path)
      end)

    assert captured =~ "Declared:"
    assert captured =~ ":http"
  end

  test "the walker matches the effects chain on any context variable name" do
    fixture = Path.expand("../fixtures/leaky_node_renamed/impl.ex", __DIR__)

    captured =
      capture_io(:stderr, fn ->
        Code.compile_file(fixture)
      end)

    assert captured =~ "effect :db used in effect_shell"
  end
end
