defmodule Bloccs.NodeMacroTest do
  use ExUnit.Case, async: true

  test "use Bloccs.Node exposes the manifest" do
    manifest = Bloccs.Test.DoubleNode.__bloccs_manifest__()
    assert manifest.id == "double"
    assert manifest.kind == :transform
  end

  test "manifest path is resolved relative to the caller file" do
    assert Bloccs.Test.DoubleNode.__bloccs_manifest_path__() =~ "fixtures/nodes/double.bloccs"
    assert File.exists?(Bloccs.Test.DoubleNode.__bloccs_manifest_path__())
  end

  test "declared effects are exposed" do
    assert Bloccs.Test.DoubleNode.__bloccs_declared_effects__() == []
  end

  test "pure_core and effect_shell refs are recorded" do
    assert %{module: Bloccs.Test.DoubleNode, function: :transform, arity: 2} =
             Bloccs.Test.DoubleNode.__bloccs_pure_core_ref__()

    assert %{module: Bloccs.Test.DoubleNode, function: :execute, arity: 2} =
             Bloccs.Test.DoubleNode.__bloccs_effect_shell_ref__()
  end
end
