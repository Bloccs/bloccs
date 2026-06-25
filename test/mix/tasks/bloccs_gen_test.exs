defmodule Mix.Tasks.Bloccs.GenTest do
  # async: false — the generators write to the current directory, so these tests
  # change the process-global cwd (via File.cd!/2); running them concurrently
  # with other tests that read relative paths would race.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bloccs.Manifest.Node
  alias Bloccs.Parser
  alias Mix.Tasks.Bloccs.Gen

  # Run a generator task inside `dir`; the tasks write relative to cwd.
  defp gen(dir, task, args) do
    capture_io(fn -> File.cd!(dir, fn -> task.run(args) end) end)
  end

  describe "bloccs.gen.node" do
    @tag :tmp_dir
    test "generates a transform node whose manifest parses", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["enrich", "--module", "MyApp"])

      manifest = Path.join(tmp, "nodes/enrich.bloccs")
      impl = Path.join(tmp, "lib/nodes/enrich.ex")

      assert File.exists?(manifest)
      assert File.exists?(impl)

      assert {:ok, %Node{} = node} = Parser.parse_node(manifest)
      assert node.id == "enrich"
      assert node.kind == :transform
      assert node.contract.pure_core.module == MyApp.Nodes.Enrich
      assert node.contract.pure_core.function == :transform
      assert node.contract.pure_core.arity == 2
      assert node.contract.effect_shell.function == :execute
      assert Map.has_key?(node.ports_in, :input)
      assert Map.has_key?(node.ports_out, :output)

      code = File.read!(impl)
      assert code =~ "defmodule MyApp.Nodes.Enrich do"
      assert code =~ ~s(use Bloccs.Node, manifest: "../../nodes/enrich.bloccs")
      assert code =~ "{:emit, :output, payload}"
    end

    @tag :tmp_dir
    test "source kind declares both ports and emits", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["ingest", "--kind", "source", "--module", "MyApp"])

      assert {:ok, %Node{} = node} = Parser.parse_node(Path.join(tmp, "nodes/ingest.bloccs"))
      assert node.kind == :source
      assert Map.has_key?(node.ports_in, :input)
      assert Map.has_key?(node.ports_out, :output)
      assert File.read!(Path.join(tmp, "lib/nodes/ingest.ex")) =~ "{:emit, :output, payload}"
    end

    @tag :tmp_dir
    test "sink kind has only in-ports and the shell drops", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["persist", "--kind", "sink", "--module", "MyApp"])

      assert {:ok, %Node{} = node} = Parser.parse_node(Path.join(tmp, "nodes/persist.bloccs"))
      assert node.kind == :sink
      assert node.ports_out == %{}
      assert Map.has_key?(node.ports_in, :input)

      assert File.read!(Path.join(tmp, "lib/nodes/persist.ex")) =~
               "def execute(_payload, _ctx), do: :drop"
    end

    @tag :tmp_dir
    test "router kind emits on a declared out-port", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["route", "--kind", "router", "--module", "MyApp"])

      assert {:ok, %Node{} = node} = Parser.parse_node(Path.join(tmp, "nodes/route.bloccs"))
      assert node.kind == :router
      assert Map.has_key?(node.ports_out, :primary)
      assert Map.has_key?(node.ports_out, :secondary)
      assert File.read!(Path.join(tmp, "lib/nodes/route.ex")) =~ "{:emit, :primary, payload}"
    end

    @tag :tmp_dir
    test "camelizes a snake_case name into the module", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["enrich_event", "--module", "MyApp"])

      assert {:ok, node} = Parser.parse_node(Path.join(tmp, "nodes/enrich_event.bloccs"))
      assert node.contract.pure_core.module == MyApp.Nodes.EnrichEvent
    end

    @tag :tmp_dir
    test "refuses to overwrite an existing node", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["enrich", "--module", "MyApp"])

      assert_raise Mix.Error, ~r/already exists/, fn ->
        capture_io(fn ->
          File.cd!(tmp, fn -> Gen.Node.run(["enrich", "--module", "MyApp"]) end)
        end)
      end
    end

    test "rejects an unknown kind" do
      assert_raise Mix.Error, ~r/unknown --kind/, fn ->
        Gen.Node.run(["x", "--kind", "frobnicate", "--module", "MyApp"])
      end
    end

    test "requires a name" do
      assert_raise Mix.Error, ~r/usage/, fn -> Gen.Node.run(["--module", "MyApp"]) end
    end
  end

  describe "bloccs.gen.network" do
    @tag :tmp_dir
    test "generates a network referencing seeded nodes that parses", %{tmp_dir: tmp} do
      gen(tmp, Gen.Node, ["ingest", "--kind", "source", "--module", "MyApp"])
      gen(tmp, Gen.Node, ["persist", "--kind", "sink", "--module", "MyApp"])
      gen(tmp, Gen.Network, ["flow", "--node", "ingest", "--node", "persist"])

      path = Path.join(tmp, "networks/flow.bloccs")
      assert File.exists?(path)

      manifest = File.read!(path)
      assert manifest =~ ~s(ingest = { use = "../nodes/ingest.bloccs" })
      assert manifest =~ ~s(persist = { use = "../nodes/persist.bloccs" })

      assert {:ok, network} = Parser.parse_network(path)
      ids = Map.keys(network.nodes)
      assert :ingest in ids
      assert :persist in ids
    end

    @tag :tmp_dir
    test "generates an empty network skeleton with no nodes", %{tmp_dir: tmp} do
      gen(tmp, Gen.Network, ["empty"])

      manifest = File.read!(Path.join(tmp, "networks/empty.bloccs"))
      assert manifest =~ "[network]"
      assert manifest =~ ~s(id      = "empty")
    end

    @tag :tmp_dir
    test "refuses to overwrite an existing network", %{tmp_dir: tmp} do
      gen(tmp, Gen.Network, ["flow"])

      assert_raise Mix.Error, ~r/already exists/, fn ->
        capture_io(fn -> File.cd!(tmp, fn -> Gen.Network.run(["flow"]) end) end)
      end
    end
  end
end
