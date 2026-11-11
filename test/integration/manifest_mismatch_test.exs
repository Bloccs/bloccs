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
    assert %{allow: ["a.local"]} = Fetch.__bloccs_manifest__().effects.http

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

  describe "mix tasks" do
    defp run_task(task, args) do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      try do
        task.run(args)
        :ok
      catch
        :exit, {:shutdown, code} -> {:exit, code}
      end
    end

    defp shell_output do
      receive do
        {:mix_shell, _kind, [line]} ->
          IO.iodata_to_binary(List.wrap(line)) <> "\n" <> shell_output()
      after
        0 -> ""
      end
    end

    test "bloccs.validate rejects a mismatched network" do
      assert {:exit, 1} = run_task(Mix.Tasks.Bloccs.Validate, ["#{@fixtures}/mm_differs.bloccs"])
      assert shell_output() =~ "differs from the embedded manifest"
    end

    test "bloccs.validate rejects a mismatched node manifest" do
      assert {:exit, 1} =
               run_task(Mix.Tasks.Bloccs.Validate, ["#{@fixtures}/fetch_no_effects.bloccs"])

      assert shell_output() =~ "Differing sections: effects"
    end

    test "bloccs.validate accepts matching manifests" do
      assert :ok = run_task(Mix.Tasks.Bloccs.Validate, ["#{@fixtures}/mm_same.bloccs"])
      assert :ok = run_task(Mix.Tasks.Bloccs.Validate, ["#{@fixtures}/fetch.bloccs"])
      refute shell_output() =~ "--no-compile"
    end

    test "bloccs.validate --no-compile skips the comparison and says so" do
      assert :ok =
               run_task(Mix.Tasks.Bloccs.Validate, [
                 "#{@fixtures}/mm_differs.bloccs",
                 "--no-compile"
               ])

      out = shell_output()
      assert out =~ "OK (network)"
      assert out =~ "--no-compile: not compared"
    end

    @tag :tmp_dir
    test "bloccs.compile rejects a mismatched network and emits nothing", %{tmp_dir: dir} do
      assert {:exit, 1} =
               run_task(Mix.Tasks.Bloccs.Compile, [
                 "#{@fixtures}/mm_differs.bloccs",
                 "--dest",
                 dir
               ])

      assert shell_output() =~ "differs from the embedded manifest"
      assert File.ls!(dir) == []
    end

    @tag :tmp_dir
    test "bloccs.compile --no-compile skips the comparison and says so", %{tmp_dir: dir} do
      assert :ok =
               run_task(Mix.Tasks.Bloccs.Compile, [
                 "#{@fixtures}/mm_differs.bloccs",
                 "--dest",
                 dir,
                 "--no-compile"
               ])

      assert shell_output() =~ "--no-compile: not compared"
      assert File.exists?(Path.join(dir, "supervisor.ex"))
    end
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
