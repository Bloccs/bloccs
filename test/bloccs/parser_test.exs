defmodule Bloccs.ParserTest do
  use ExUnit.Case, async: true

  alias Bloccs.Manifest.{Node, Network, Edge, NetworkNode, Effects, Contract, Doc, Port}
  alias Bloccs.Parser

  @enrich ~S"""
  [node]
  id      = "enrich"
  version = "1.2.0"
  kind    = "transform"

  [doc]
  intent = "Enrich an event from an HTTP lookup and persist the outcome."
  owner  = "@example"

  [ports.in]
  event = { schema = "Event@1", buffer = 100 }

  [ports.out]
  enriched = { schema = "EnrichedEvent@1" }
  failed   = { schema = "FailedEvent@1" }

  [effects]
  http   = { allow = ["enrichment.local"], methods = ["GET"] }
  db     = { allow = ["events:insert"] }
  time   = "wall_clock"
  random = "none"

  [contract]
  pure_core    = "Demo.Nodes.Enrich.transform/2"
  effect_shell = "Demo.Nodes.Enrich.execute/2"
  retry        = { strategy = "exponential", max = 3, on = ["network", "http_5xx"] }
  timeout_ms   = 5000
  idempotency  = { key = "fields:tenant_id,event_id" }

  [observability]
  metrics = ["duration_ms", "outcome"]
  traces  = "auto"
  """

  describe "parse_node_string/1" do
    test "parses a fully-populated node manifest" do
      assert {:ok, %Node{} = node} = Parser.parse_node_string(@enrich)

      assert node.id == "enrich"
      assert node.version == "1.2.0"
      assert node.kind == :transform

      assert %Doc{intent: "Enrich an event" <> _, owner: "@example"} = node.doc

      assert %{
               event: %Port{
                 name: :event,
                 schema: "Event@1",
                 buffer: 100
               }
             } = node.ports_in

      assert Map.keys(node.ports_out) |> Enum.sort() ==
               [:enriched, :failed]

      assert %Effects{
               http: %{allow: ["enrichment.local"], methods: ["GET"]},
               db: %{allow: ["events:insert"]},
               time: "wall_clock",
               random: "none"
             } = node.effects

      assert %Contract{
               pure_core: %{
                 module: Demo.Nodes.Enrich,
                 function: :transform,
                 arity: 2
               },
               effect_shell: %{
                 module: Demo.Nodes.Enrich,
                 function: :execute,
                 arity: 2
               },
               retry: %{strategy: "exponential", max: 3, on: ["network", "http_5xx"]},
               timeout_ms: 5000,
               idempotency: %{key: "fields:tenant_id,event_id"}
             } = node.contract
    end

    test "missing required section is reported" do
      assert {:error, errors} =
               Parser.parse_node_string(~S"""
               [node]
               id = "foo"
               version = "0.1.0"
               kind = "transform"
               """)

      assert Enum.any?(errors, &(&1.message =~ "[ports.in]"))
      assert Enum.any?(errors, &(&1.message =~ "[ports.out]"))
      assert Enum.any?(errors, &(&1.message =~ "[effects]"))
      assert Enum.any?(errors, &(&1.message =~ "[contract]"))
    end

    test "unknown kind reports the name" do
      assert {:error, errors} =
               Parser.parse_node_string(~S"""
               [node]
               id = "foo"
               version = "0.1.0"
               kind = "monstrous"

               [ports.in]
               [ports.out]
               [effects]
               [contract]
               pure_core = "Foo.Bar.x/2"
               effect_shell = "Foo.Bar.y/2"
               """)

      assert Enum.any?(errors, &(&1.message =~ "monstrous"))
    end
  end

  describe "parse_node/1" do
    @tag :tmp_dir
    test "parses from a file and stores the path", %{tmp_dir: tmp} do
      path = Path.join(tmp, "enrich.bloccs")
      File.write!(path, @enrich)

      assert {:ok, node} = Parser.parse_node(path)
      assert node.path == path
    end
  end

  describe "parse_network/1" do
    @tag :tmp_dir
    test "parses a minimal network", %{tmp_dir: tmp} do
      node_path = Path.join(tmp, "enrich.bloccs")
      File.write!(node_path, @enrich)

      File.write!(Path.join(tmp, "ingest.bloccs"), node_with_ports("ingest", "http_in", "out_a"))
      File.write!(Path.join(tmp, "log.bloccs"), node_with_ports("log", "in_b", "noop"))

      network_path = Path.join(tmp, "demo.bloccs")

      File.write!(network_path, ~S"""
      [network]
      id = "demo"
      version = "0.1.0"

      [nodes]
      ingest = { use = "ingest.bloccs" }
      enrich = { use = "enrich.bloccs" }
      log    = { use = "log.bloccs" }

      [[edges]]
      from = "ingest.out_a"
      to   = "enrich.event"

      [[edges]]
      from = "enrich.enriched"
      to   = ["log.in_b"]

      [supervision]
      strategy = "rest_for_one"
      max_restarts = 5
      max_seconds = 60
      """)

      assert {:ok, %Network{} = net} = Parser.parse_network(network_path)
      assert net.id == "demo"
      assert net.supervision.strategy == :rest_for_one
      assert net.supervision.max_restarts == 5

      assert %{ingest: %NetworkNode{}, enrich: %NetworkNode{}, log: %NetworkNode{}} = net.nodes

      assert [
               %Edge{from: {:ingest, :out_a}, to: [{:enrich, :event}]},
               %Edge{from: {:enrich, :enriched}, to: [{:log, :in_b}]}
             ] = net.edges
    end

    @tag :tmp_dir
    test "a missing subgraph file surfaces a read error scoped to the node", %{tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "outer.bloccs"),
        ~S"""
        [network]
        id = "outer"
        version = "0.1.0"

        [nodes]
        inner = { use = "missing.bloccs" }
        """
      )

      assert {:error, errors} = Parser.parse_network(Path.join(tmp, "outer.bloccs"))
      assert Enum.any?(errors, &(&1.section =~ "[nodes].inner"))
    end
  end

  describe "parse_network/1 subgraph composition" do
    @tag :tmp_dir
    test "flattens a sub-network into namespaced nodes and rewrites edges", %{tmp_dir: tmp} do
      write_subgraph_fixtures(tmp)

      assert {:ok, %Network{} = net} = Parser.parse_network(Path.join(tmp, "outer.bloccs"))

      # leaf node `src` plus the subgraph's two leaves, namespaced under `sub`.
      assert Map.keys(net.nodes) |> Enum.sort() == [:src, :"sub.a", :"sub.b"]
      assert %NetworkNode{local_id: :"sub.a"} = net.nodes[:"sub.a"]

      # internal sub edge a->b is namespaced; parent edge src->sub.inbound is
      # rewritten to the exposed internal endpoint (sub.a.in_a); sub.outbound is
      # exposed from sub.b.out_b.
      assert {:src, :out_a} in Enum.map(net.edges, & &1.from)

      assert Enum.any?(
               net.edges,
               &(&1.from == {:"sub.a", :out_a} and &1.to == [{:"sub.b", :in_a}])
             )

      assert Enum.any?(net.edges, &(&1.to == [{:"sub.a", :in_a}]))
    end

    @tag :tmp_dir
    test "errors when a parent edge targets an unexposed subgraph port", %{tmp_dir: tmp} do
      write_subgraph_fixtures(tmp, parent_to: "sub.nope")

      assert {:error, errors} = Parser.parse_network(Path.join(tmp, "outer.bloccs"))
      assert Enum.any?(errors, &(&1.message =~ "does not expose"))
    end

    @tag :tmp_dir
    test "rejects a composition cycle", %{tmp_dir: tmp} do
      # a.bloccs uses b.bloccs which uses a.bloccs
      File.write!(Path.join(tmp, "leaf.bloccs"), node_with_ports("leaf", "in_a", "out_a"))

      cyclic = fn id, other ->
        ~s"""
        [network]
        id = "#{id}"
        version = "0.1.0"

        [nodes]
        sub = { use = "#{other}.bloccs" }

        [expose]
        in  = { i = "sub.i" }
        out = { o = "sub.o" }
        """
      end

      File.write!(Path.join(tmp, "a.bloccs"), cyclic.("a", "b"))
      File.write!(Path.join(tmp, "b.bloccs"), cyclic.("b", "a"))

      assert {:error, errors} = Parser.parse_network(Path.join(tmp, "a.bloccs"))
      assert Enum.any?(errors, &(&1.message =~ "cycle"))
    end

    @tag :tmp_dir
    test "rejects a config overlay on a subgraph use", %{tmp_dir: tmp} do
      write_subgraph_fixtures(tmp, parent_config: ~s(, config = { x = 1 }))

      assert {:error, errors} = Parser.parse_network(Path.join(tmp, "outer.bloccs"))
      assert Enum.any?(errors, &(&1.message =~ "config overlay"))
    end
  end

  # outer.bloccs (src -> sub) composing sub.bloccs (a -> b), which exposes
  # in `inbound` -> a.in_a and out `outbound` -> b.out_b.
  defp write_subgraph_fixtures(tmp, opts \\ []) do
    parent_to = Keyword.get(opts, :parent_to, "sub.inbound")
    parent_config = Keyword.get(opts, :parent_config, "")

    File.write!(Path.join(tmp, "a.bloccs"), node_with_ports("a", "in_a", "out_a"))
    File.write!(Path.join(tmp, "b.bloccs"), node_with_ports("b", "in_a", "out_b"))

    File.write!(Path.join(tmp, "sub.bloccs"), ~S"""
    [network]
    id = "sub"
    version = "0.1.0"

    [nodes]
    a = { use = "a.bloccs" }
    b = { use = "b.bloccs" }

    [[edges]]
    from = "a.out_a"
    to   = "b.in_a"

    [expose]
    in  = { inbound = "a.in_a" }
    out = { outbound = "b.out_b" }
    """)

    File.write!(Path.join(tmp, "src.bloccs"), node_with_ports("src", "in_a", "out_a"))

    File.write!(Path.join(tmp, "outer.bloccs"), """
    [network]
    id = "outer"
    version = "0.1.0"

    [nodes]
    src = { use = "src.bloccs" }
    sub = { use = "sub.bloccs"#{parent_config} }

    [[edges]]
    from = "src.out_a"
    to   = "#{parent_to}"
    """)
  end

  describe "malformed manifests return structured errors (never raise)" do
    # Append a malformed section to an otherwise-valid node and assert the
    # parser reports it as a structured error instead of crashing.
    defp parse_node_with(extra) do
      Parser.parse_node_string(node_with_ports("m", "a", "b") <> "\n" <> extra)
    end

    defp messages({:error, errors}), do: Enum.map(errors, & &1.message)

    test "non-string join deadletter" do
      result = parse_node_with("[join]\non = \"id\"\ndeadletter = 5\n")
      assert Enum.any?(messages(result), &(&1 =~ "deadletter must be a port name string"))
    end

    test "non-string entries in http methods" do
      result =
        Parser.parse_node_string("""
        [node]
        id = "m"
        version = "0.1.0"
        kind = "transform"

        [ports.in]
        a = { schema = "Anything@1" }

        [ports.out]
        b = { schema = "Anything@1" }

        [effects]
        http = { allow = ["x.local"], methods = [1] }

        [contract]
        pure_core = "Bloccs.Stub.transform/2"
        effect_shell = "Bloccs.Stub.execute/2"
        """)

      assert Enum.any?(messages(result), &(&1 =~ "methods must be a list of strings"))
    end

    test "unknown effect axis is an error, not silently dropped" do
      result =
        Parser.parse_node_string("""
        [node]
        id = "m"
        version = "0.1.0"
        kind = "transform"

        [ports.in]
        a = { schema = "Anything@1" }

        [ports.out]
        b = { schema = "Anything@1" }

        [effects]
        htttp = { allow = ["x.local"] }

        [contract]
        pure_core = "Bloccs.Stub.transform/2"
        effect_shell = "Bloccs.Stub.execute/2"
        """)

      assert Enum.any?(messages(result), &(&1 =~ ~s(unknown effect axis "htttp")))
    end

    test "non-list http allow is an error, not a silent nil" do
      result =
        Parser.parse_node_string("""
        [node]
        id = "m"
        version = "0.1.0"
        kind = "transform"

        [ports.in]
        a = { schema = "Anything@1" }

        [ports.out]
        b = { schema = "Anything@1" }

        [effects]
        http = { allow = "x.local" }

        [contract]
        pure_core = "Bloccs.Stub.transform/2"
        effect_shell = "Bloccs.Stub.execute/2"
        """)

      assert Enum.any?(messages(result), &(&1 =~ "http must be"))
    end

    test "non-string time/random axes" do
      result = parse_node_with("")

      assert {:ok, _} = result

      result2 =
        Parser.parse_node_string(
          String.replace(node_with_ports("m", "a", "b"), "[effects]", "[effects]\ntime = 5")
        )

      assert Enum.any?(messages(result2), &(&1 =~ "time must be a string"))
    end

    @tag :tmp_dir
    test "expose endpoints without a dot or with a non-string value", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "n.bloccs"), node_with_ports("n", "a", "b"))

      path = Path.join(tmp, "net.bloccs")

      File.write!(path, """
      [network]
      id = "net"
      version = "0.1.0"

      [nodes]
      n = { use = "n.bloccs" }

      [expose.in]
      nodot = "justaname"
      notastring = 5
      """)

      assert {:error, errors} = Parser.parse_network(path)
      msgs = Enum.map(errors, & &1.message)
      assert Enum.any?(msgs, &(&1 =~ ~s(endpoint must be "node.port")))
      assert Enum.any?(msgs, &(&1 =~ "got 5"))
    end

    @tag :tmp_dir
    test "non-map expose section", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "n.bloccs"), node_with_ports("n", "a", "b"))
      path = Path.join(tmp, "net.bloccs")

      File.write!(path, """
      [network]
      id = "net"
      version = "0.1.0"

      [nodes]
      n = { use = "n.bloccs" }

      [expose]
      in = "x"
      """)

      assert {:error, errors} = Parser.parse_network(path)
      assert Enum.any?(errors, &(&1.message =~ "expected a table"))
    end

    @tag :tmp_dir
    test "non-string use path", %{tmp_dir: tmp} do
      path = Path.join(tmp, "net.bloccs")

      File.write!(path, """
      [network]
      id = "net"
      version = "0.1.0"

      [nodes]
      n = { use = 5 }
      """)

      assert {:error, errors} = Parser.parse_network(path)
      assert Enum.any?(errors, &(&1.message =~ "expected { use ="))
    end

    @tag :tmp_dir
    test "non-table deploy concurrency", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "n.bloccs"), node_with_ports("n", "a", "b"))
      path = Path.join(tmp, "net.bloccs")

      File.write!(path, """
      [network]
      id = "net"
      version = "0.1.0"

      [nodes]
      n = { use = "n.bloccs" }

      [deploy]
      concurrency = "lots"
      """)

      assert {:error, errors} = Parser.parse_network(path)
      assert Enum.any?(errors, &(&1.message =~ "concurrency must be a table"))
    end
  end

  defp node_with_ports(id, in_port, out_port) do
    """
    [node]
    id = "#{id}"
    version = "0.1.0"
    kind = "transform"

    [ports.in]
    #{in_port} = { schema = "Anything@1" }

    [ports.out]
    #{out_port} = { schema = "Anything@1" }

    [effects]

    [contract]
    pure_core = "Bloccs.Stub.transform/2"
    effect_shell = "Bloccs.Stub.execute/2"
    """
  end
end
