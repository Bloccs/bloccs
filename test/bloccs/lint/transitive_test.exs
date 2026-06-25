defmodule Bloccs.Lint.TransitiveTest do
  @moduledoc """
  The transitive pass follows a node's `pure_core` / `effect_shell` into the
  same-application helpers they call — the reachability the intraprocedural
  `Bloccs.Node.EffectLint` deliberately does not traverse. Fixtures
  (`test/support/helper_leak.ex`) are compiled into the test build, so their
  BEAM abstract code is available to `Bloccs.Lint.Beam`.
  """

  use ExUnit.Case, async: true

  alias Bloccs.Lint.Transitive

  @leak_node Bloccs.Test.HelperLeak.Node

  test "follows the node body into a same-app helper and flags its File.write!" do
    violations = Transitive.lint(@leak_node)

    assert Enum.any?(violations, &(&1.reason =~ "file IO")),
           "expected a file-IO violation, got: #{inspect(violations)}"
  end

  test "the flagged call is attributed to the helper, reached from effect_shell" do
    violations = Transitive.lint(@leak_node)
    leak = Enum.find(violations, &(&1.reason =~ "file IO"))

    assert leak.kind == :effect_shell
    assert leak.at =~ "Bloccs.Test.HelperLeak.Writer.persist"
  end

  test "the pure helper reachable from pure_core is not flagged" do
    violations = Transitive.lint(@leak_node)
    # Clean.normalize/1 uses only Map.* — the pure_core path must be clean.
    refute Enum.any?(violations, &(&1.kind == :pure_core))
  end

  test "the events example nodes are transitively clean (no false positives)" do
    nodes = [
      Events.Nodes.Validate,
      Events.Nodes.Enrich,
      Events.Nodes.Route,
      Events.Nodes.Persist,
      Events.Nodes.Notify,
      Events.Nodes.Deadletter,
      Events.Nodes.Ingest
    ]

    for mod <- nodes do
      assert Transitive.lint(mod) == [],
             "#{inspect(mod)} should be transitively clean, got: #{inspect(Transitive.lint(mod))}"
    end
  end
end
