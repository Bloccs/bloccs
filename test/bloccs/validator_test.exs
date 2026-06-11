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

  describe "validate_node/2 [join]" do
    defp join_node(join_block, opts \\ []) do
      ins =
        Keyword.get(
          opts,
          :ins,
          ~s(left  = { schema = "A@1" }\n      right = { schema = "B@1" })
        )

      """
      [node]
      id = "j"
      version = "0.1.0"
      kind = "transform"

      [ports.in]
      #{ins}

      [ports.out]
      joined     = { schema = "C@1" }
      deadletter = { schema = "D@1" }

      [effects]

      #{join_block}

      [contract]
      pure_core = "Bloccs.Stub.transform/2"
      effect_shell = "Bloccs.Stub.execute/2"
      """
    end

    test "accepts a well-formed [join] node" do
      raw = join_node(~s([join]\non = "id"\ntimeout_ms = 100\ndeadletter = "deadletter"))
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert :ok = Validator.validate_node(node)
    end

    test "rejects a join with fewer than two in-ports" do
      raw = join_node(~s([join]\non = "id"), ins: ~s(only = { schema = "A@1" }))
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "at least two input ports"))
    end

    test "rejects a deadletter naming an unknown out-port" do
      raw = join_node(~s([join]\non = "id"\ndeadletter = "nope"))
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "unknown out-port"))
    end

    test "rejects combining [join] with [batch]" do
      raw = join_node(~s([join]\non = "id"\n\n[batch]\nsize = 10))
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "cannot be both a [join] and a [batch]"))
    end
  end

  describe "validate_node/2 [rate] / [delay]" do
    test "accepts [rate] and [delay] on a plain node" do
      raw = batch_node("[rate]\nallowed = 10\ninterval_ms = 1000\n\n[delay]\nms = 50")
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert :ok = Validator.validate_node(node)
    end

    test "rejects a non-positive [rate].allowed" do
      raw = batch_node("[rate]\nallowed = 0\ninterval_ms = 1000")
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "positive integer"))
    end

    test "rejects a non-positive [delay].ms" do
      raw = batch_node("[delay]\nms = 0")
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "positive integer"))
    end

    test "rejects [rate] on a [join] node" do
      raw = join_node(~s([join]\non = "id"\n\n[rate]\nallowed = 1\ninterval_ms = 1000))
      assert {:ok, node} = Parser.parse_node_string(raw)
      assert {:error, issues} = Validator.validate_node(node)
      assert Enum.any?(issues, &(&1.message =~ "not supported on a [join]"))
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

    @tag :tmp_dir
    test "diamond-chain DAGs validate without exponential blowup", %{tmp_dir: tmp} do
      # 40 stacked diamonds (121 nodes). Without cross-path memoization the
      # DFS enumerates 2^40 paths and this test never finishes.
      layers = 40

      node_ids = ["n0"] ++ Enum.flat_map(1..layers, fn i -> ["l#{i}", "r#{i}", "n#{i}"] end)

      for id <- node_ids do
        File.write!(
          Path.join(tmp, "#{id}.bloccs"),
          tmp_node_with(id, "input", "X@1", "output", "X@1")
        )
      end

      nodes_section = Enum.map_join(node_ids, "\n", &"#{&1} = { use = \"#{&1}.bloccs\" }")

      edges_section =
        1..layers
        |> Enum.flat_map(fn i ->
          prev = "n#{i - 1}"

          [
            {"#{prev}.output", "l#{i}.input"},
            {"#{prev}.output", "r#{i}.input"},
            {"l#{i}.output", "n#{i}.input"},
            {"r#{i}.output", "n#{i}.input"}
          ]
        end)
        |> Enum.map_join("\n", fn {f, t} ->
          "[[edges]]\nfrom = \"#{f}\"\nto = \"#{t}\"\n"
        end)

      net_path = Path.join(tmp, "net.bloccs")

      File.write!(net_path, """
      [network]
      id = "diamonds"
      version = "0.1.0"

      [nodes]
      #{nodes_section}

      #{edges_section}
      """)

      assert {:ok, network} = Parser.parse_network(net_path)

      {micros, result} = :timer.tc(fn -> Validator.validate_network(network) end)
      assert :ok = result
      # Linear-time validation of ~120 nodes is sub-millisecond; 2s leaves
      # enormous headroom for slow CI while still catching a blowup.
      assert micros < 2_000_000
    end
  end
end
