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
    test "subgraph composition is rejected as deferred", %{tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "payments.bloccs"),
        ~S"""
        [network]
        id = "outer"
        version = "0.1.0"

        [nodes]
        inner = { use = "networks/inner.bloccs" }
        """
      )

      assert {:error, errors} = Parser.parse_network(Path.join(tmp, "payments.bloccs"))
      assert Enum.any?(errors, &(&1.message =~ "deferred to v0.2"))
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
