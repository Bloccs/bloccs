defmodule Bloccs.NodeMacroUnwiredFieldsTest do
  @moduledoc """
  Confirms `Bloccs.Node`'s `__using__/1` emits a structured `IO.warn`
  listing every parsed-but-unwired manifest field declared by the node.

  Closes pre-pitch checklist item #3 from `docs/v0.1-audit.md`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bloccs.{Parser, Validator}

  @fixture_path Path.expand("../fixtures/unwired_node/impl.ex", __DIR__)
  @manifest_path Path.expand("../fixtures/unwired_node/manifest.bloccs", __DIR__)

  describe "Validator.warnings/1 on a manifest with unwired fields" do
    test "returns one Issue per declared unwired field" do
      assert {:ok, manifest} = Parser.parse_node(@manifest_path)
      warnings = Validator.warnings(manifest)

      scopes = warnings |> Enum.map(& &1.scope) |> Enum.sort()

      assert "[contract].retry" in scopes
      assert "[contract].timeout_ms" in scopes
      assert "[contract].idempotency" in scopes
      assert "[ports.in].in_a.buffer" in scopes
      assert "[observability].metrics" in scopes
      assert "[observability].traces" in scopes

      assert Enum.all?(warnings, &(&1.level == :warning))
    end

    test "returns [] for a manifest with no unwired fields" do
      manifest = %Bloccs.Manifest.Node{
        id: "clean",
        version: "0.1.0",
        kind: :transform,
        ports_in: %{},
        ports_out: %{},
        effects: %Bloccs.Manifest.Effects{},
        contract: %Bloccs.Manifest.Contract{
          pure_core: %{module: A, function: :t, arity: 2},
          effect_shell: %{module: A, function: :e, arity: 2}
        }
      }

      assert [] = Validator.warnings(manifest)
    end
  end

  describe "Bloccs.Node macro" do
    test "emits a summarized IO.warn pointing at docs/v0.1-audit.md" do
      captured =
        capture_io(:stderr, fn ->
          Code.compile_file(@fixture_path)
        end)

      assert captured =~ "bloccs node `unwired_demo` declares fields not yet wired"
      assert captured =~ "[contract].retry"
      assert captured =~ "[contract].timeout_ms"
      assert captured =~ "[contract].idempotency"
      assert captured =~ "[ports.in].in_a.buffer"
      assert captured =~ "[observability].metrics"
      assert captured =~ "[observability].traces"
      assert captured =~ "docs/v0.1-audit.md"
    end
  end
end
