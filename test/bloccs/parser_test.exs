defmodule Bloccs.ParserTest do
  use ExUnit.Case, async: true

  alias Bloccs.Manifest.{Node, Network, Edge, NetworkNode, Effects, Contract, Doc, Port}
  alias Bloccs.Parser

  @charge_customer ~S"""
  [node]
  id      = "charge_customer"
  version = "1.2.0"
  kind    = "transform"

  [doc]
  intent = "Charge a customer one-time via Stripe and persist the outcome."
  owner  = "@payments"

  [ports.in]
  charge_requested = { schema = "ChargeRequest@1", buffer = 100 }

  [ports.out]
  charge_completed = { schema = "ChargeCompleted@1" }
  charge_failed    = { schema = "ChargeFailed@1" }

  [effects]
  http   = { allow = ["api.stripe.com"], methods = ["POST"] }
  db     = { allow = ["charges:insert"] }
  time   = "wall_clock"
  random = "none"

  [contract]
  pure_core    = "Bloccs.Payments.ChargeCustomer.transform/2"
  effect_shell = "Bloccs.Payments.ChargeCustomer.execute/2"
  retry        = { strategy = "exponential", max = 3, on = ["network", "stripe_5xx"] }
  timeout_ms   = 5000
  idempotency  = { key = "fields:customer_id,request_id" }

  [observability]
  metrics = ["duration_ms", "outcome"]
  traces  = "auto"
  """

  describe "parse_node_string/1" do
    test "parses the charge_customer manifest from research/01" do
      assert {:ok, %Node{} = node} = Parser.parse_node_string(@charge_customer)

      assert node.id == "charge_customer"
      assert node.version == "1.2.0"
      assert node.kind == :transform

      assert %Doc{intent: "Charge a customer" <> _, owner: "@payments"} = node.doc

      assert %{
               charge_requested: %Port{
                 name: :charge_requested,
                 schema: "ChargeRequest@1",
                 buffer: 100
               }
             } = node.ports_in

      assert Map.keys(node.ports_out) |> Enum.sort() ==
               [:charge_completed, :charge_failed]

      assert %Effects{
               http: %{allow: ["api.stripe.com"], methods: ["POST"]},
               db: %{allow: ["charges:insert"]},
               time: "wall_clock",
               random: "none"
             } = node.effects

      assert %Contract{
               pure_core: %{
                 module: Bloccs.Payments.ChargeCustomer,
                 function: :transform,
                 arity: 2
               },
               effect_shell: %{
                 module: Bloccs.Payments.ChargeCustomer,
                 function: :execute,
                 arity: 2
               },
               retry: %{strategy: "exponential", max: 3, on: ["network", "stripe_5xx"]},
               timeout_ms: 5000,
               idempotency: %{key: "fields:customer_id,request_id"}
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
      path = Path.join(tmp, "charge_customer.bloccs")
      File.write!(path, @charge_customer)

      assert {:ok, node} = Parser.parse_node(path)
      assert node.path == path
    end
  end

  describe "parse_network/1" do
    @tag :tmp_dir
    test "parses a minimal payments network", %{tmp_dir: tmp} do
      node_path = Path.join(tmp, "charge_customer.bloccs")
      File.write!(node_path, @charge_customer)

      File.write!(Path.join(tmp, "ingest.bloccs"), node_with_ports("ingest", "http_in", "out_a"))
      File.write!(Path.join(tmp, "log.bloccs"), node_with_ports("log", "in_b", "noop"))

      network_path = Path.join(tmp, "payments.bloccs")

      File.write!(network_path, ~S"""
      [network]
      id = "payments"
      version = "0.1.0"

      [nodes]
      ingest = { use = "ingest.bloccs" }
      charge = { use = "charge_customer.bloccs" }
      log    = { use = "log.bloccs" }

      [[edges]]
      from = "ingest.out_a"
      to   = "charge.charge_requested"

      [[edges]]
      from = "charge.charge_completed"
      to   = ["log.in_b"]

      [supervision]
      strategy = "rest_for_one"
      max_restarts = 5
      max_seconds = 60
      """)

      assert {:ok, %Network{} = net} = Parser.parse_network(network_path)
      assert net.id == "payments"
      assert net.supervision.strategy == :rest_for_one
      assert net.supervision.max_restarts == 5

      assert %{ingest: %NetworkNode{}, charge: %NetworkNode{}, log: %NetworkNode{}} = net.nodes

      assert [
               %Edge{from: {:ingest, :out_a}, to: [{:charge, :charge_requested}]},
               %Edge{from: {:charge, :charge_completed}, to: [{:log, :in_b}]}
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
      assert Enum.any?(net.edges, &(&1.from == {:"sub.a", :out_a} and &1.to == [{:"sub.b", :in_a}]))
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
