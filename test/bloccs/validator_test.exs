defmodule Bloccs.ValidatorTest do
  use ExUnit.Case, async: true

  alias Bloccs.{Parser, Validator}

  defp tmp_node_with(id, in_port, in_schema, out_port, out_schema) do
    """
    [node]
    id = "#{id}"
    version = "0.1.0"
    kind = "transform"

    [ports.in]
    #{in_port} = { schema = "#{in_schema}" }

    [ports.out]
    #{out_port} = { schema = "#{out_schema}" }

    [effects]

    [contract]
    pure_core = "Bloccs.Stub.transform/2"
    effect_shell = "Bloccs.Stub.execute/2"
    """
  end

  describe "validate_node/2" do
    test "accepts a well-formed node" do
      assert {:ok, node} =
               Parser.parse_node_string(tmp_node_with("a", "i", "X@1", "o", "Y@1"))

      assert :ok = Validator.validate_node(node)
    end

    test "rejects malformed schema id" do
      raw =
        tmp_node_with("a", "i", "lowercase@1", "o", "Y@1")

      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "Name@N"))
    end

    test "rejects a node with more than one input port (v0.1 single-input)" do
      raw = """
      [node]
      id = "multi"
      version = "0.1.0"
      kind = "transform"

      [ports.in]
      first  = { schema = "X@1" }
      second = { schema = "Y@1" }

      [ports.out]
      o = { schema = "Z@1" }

      [effects]

      [contract]
      pure_core = "Bloccs.Stub.transform/2"
      effect_shell = "Bloccs.Stub.execute/2"
      """

      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "at most one input port"))
    end
  end

  describe "validate_node/2 [batch]" do
    defp batch_node(batch_block, extra_contract \\ "") do
      """
      [node]
      id = "agg"
      version = "0.1.0"
      kind = "transform"

      [ports.in]
      i = { schema = "X@1" }

      [ports.out]
      o = { schema = "Y@1" }

      [effects]

      #{batch_block}

      [contract]
      pure_core = "Bloccs.Stub.transform/2"
      effect_shell = "Bloccs.Stub.execute/2"
      #{extra_contract}
      """
    end

    test "accepts a well-formed [batch] node" do
      assert {:ok, node} =
               Parser.parse_node_string(batch_node("[batch]\nsize = 100\ntimeout_ms = 500"))

      assert :ok = Validator.validate_node(node)
    end

    test "rejects an empty [batch] (neither size nor timeout_ms)" do
      assert {:ok, node} = Parser.parse_node_string(batch_node("[batch]"))
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "at least one of"))
    end

    test "rejects a non-positive size" do
      assert {:ok, node} = Parser.parse_node_string(batch_node("[batch]\nsize = 0"))
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "positive integer"))
    end

    test "rejects combining [batch] with [contract].retry (unsupported)" do
      raw =
        batch_node("[batch]\nsize = 10", ~s(retry = { strategy = "constant", max = 2, on = [] }))

      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "cannot also declare [contract].retry"))
    end
  end

  describe "validate_network/2" do
    @tag :tmp_dir
    test "accepts a well-formed two-node DAG", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "a.bloccs"), tmp_node_with("a", "in_a", "X@1", "out_a", "Y@1"))
      File.write!(Path.join(tmp, "b.bloccs"), tmp_node_with("b", "in_b", "Y@1", "out_b", "Z@1"))

      net_path = Path.join(tmp, "net.bloccs")

      File.write!(net_path, ~S"""
      [network]
      id = "net"
      version = "0.1.0"

      [nodes]
      a = { use = "a.bloccs" }
      b = { use = "b.bloccs" }

      [[edges]]
      from = "a.out_a"
      to   = "b.in_b"
      """)

      assert {:ok, network} = Parser.parse_network(net_path)
      assert :ok = Validator.validate_network(network)
    end

    @tag :tmp_dir
    test "detects edge schema mismatch", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "a.bloccs"), tmp_node_with("a", "in_a", "X@1", "out_a", "Y@1"))
      File.write!(Path.join(tmp, "b.bloccs"), tmp_node_with("b", "in_b", "Z@1", "out_b", "W@1"))

      net_path = Path.join(tmp, "net.bloccs")

      File.write!(net_path, ~S"""
      [network]
      id = "n"
      version = "0.1.0"

      [nodes]
      a = { use = "a.bloccs" }
      b = { use = "b.bloccs" }

      [[edges]]
      from = "a.out_a"
      to   = "b.in_b"
      """)

      assert {:ok, network} = Parser.parse_network(net_path)
      assert {:error, issues} = Validator.validate_network(network)
      assert Enum.any?(issues, &(&1.message =~ "schema mismatch"))
    end

    @tag :tmp_dir
    test "detects unknown port", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "a.bloccs"), tmp_node_with("a", "in_a", "X@1", "out_a", "Y@1"))
      File.write!(Path.join(tmp, "b.bloccs"), tmp_node_with("b", "in_b", "Y@1", "out_b", "Z@1"))

      net_path = Path.join(tmp, "net.bloccs")

      File.write!(net_path, ~S"""
      [network]
      id = "n"
      version = "0.1.0"

      [nodes]
      a = { use = "a.bloccs" }
      b = { use = "b.bloccs" }

      [[edges]]
      from = "a.does_not_exist"
      to   = "b.in_b"
      """)

      assert {:ok, network} = Parser.parse_network(net_path)
      assert {:error, issues} = Validator.validate_network(network)
      assert Enum.any?(issues, &(&1.message =~ "unknown port"))
    end

    @tag :tmp_dir
    test "detects cycles", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "a.bloccs"), tmp_node_with("a", "in_a", "X@1", "out_a", "X@1"))
      File.write!(Path.join(tmp, "b.bloccs"), tmp_node_with("b", "in_b", "X@1", "out_b", "X@1"))

      net_path = Path.join(tmp, "net.bloccs")

      File.write!(net_path, ~S"""
      [network]
      id = "n"
      version = "0.1.0"

      [nodes]
      a = { use = "a.bloccs" }
      b = { use = "b.bloccs" }

      [[edges]]
      from = "a.out_a"
      to   = "b.in_b"

      [[edges]]
      from = "b.out_b"
      to   = "a.in_a"
      """)

      assert {:ok, network} = Parser.parse_network(net_path)
      assert {:error, issues} = Validator.validate_network(network)
      assert Enum.any?(issues, &(&1.message =~ "cycle"))
    end
  end
end
