defmodule Bloccs.Integration.ManifestMismatchTest do
  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Validator}
  alias Bloccs.Integration.ManifestMismatchFixtures.Fetch

  @fixtures "test/fixtures/manifest_mismatch"

  defp parse!(name) do
    {:ok, network} = Parser.parse_network(Path.join(@fixtures, name))
    network
  end

  test "a network that references each module's own manifest is accepted" do
    network = parse!("mm_same.bloccs")

    assert :ok = Validator.validate_network(network)
    assert :ok = Compiler.check_embedded_manifests(network)
  end

  test "a manifest that differs from the module's embedded manifest is rejected" do
    network = parse!("mm_differs.bloccs")

    # The referenced manifest is valid on its own and declares no effects, while
    # the module it points at was compiled with an HTTP grant.
    assert :ok = Validator.validate_network(network)
    assert network.nodes[:fetch].manifest.effects.http == nil
    assert Fetch.__bloccs_manifest__().effects.http != nil

    assert {:error, [issue]} = Compiler.check_embedded_manifests(network)
    assert issue.scope == "[nodes].fetch"
    assert issue.message =~ "fetch_no_effects.bloccs"
    assert issue.message =~ "embedded manifest"
    assert issue.message =~ "Differing sections: effects"
  end

  test "compile_and_load refuses to load a mismatched network" do
    network = parse!("mm_differs.bloccs")

    assert {:error, [%Validator.Issue{scope: "[nodes].fetch"}]} =
             Compiler.compile_and_load(network)

    refute Code.ensure_loaded?(Compiler.Network.supervisor_module(network))
  end

  test "a node whose module is not loadable is skipped" do
    network = parse!("mm_same.bloccs")
    fetch = network.nodes[:fetch]
    contract = fetch.manifest.contract
    missing = %{contract | pure_core: %{contract.pure_core | module: No.Such.Module}}

    nodes =
      Map.put(network.nodes, :fetch, %{fetch | manifest: %{fetch.manifest | contract: missing}})

    assert :ok = Compiler.check_embedded_manifests(%{network | nodes: nodes})
  end
end
