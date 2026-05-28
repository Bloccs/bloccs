defmodule Bloccs.CoverageTest do
  use ExUnit.Case, async: true

  alias Bloccs.{Parser, Coverage}

  defp tmp_node(id, in_port, in_schema, out_port, out_schema) do
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
    pure_core = "Stub.transform/2"
    effect_shell = "Stub.execute/2"
    """
  end

  @tag :tmp_dir
  test "enumerates one in + one out per node plus every edge", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "a.bloccs"), tmp_node("a", "i", "X@1", "o", "Y@1"))
    File.write!(Path.join(tmp, "b.bloccs"), tmp_node("b", "i", "Y@1", "o", "Z@1"))

    network_path = Path.join(tmp, "n.bloccs")

    File.write!(network_path, ~S"""
    [network]
    id = "covdemo"
    version = "0.1.0"

    [nodes]
    a = { use = "a.bloccs" }
    b = { use = "b.bloccs" }

    [[edges]]
    from = "a.o"
    to   = "b.i"
    """)

    {:ok, network} = Parser.parse_network(network_path)
    obs = Coverage.obligations(network)

    assert {:port_in, :a, :i} in obs
    assert {:port_out, :a, :o} in obs
    assert {:port_in, :b, :i} in obs
    assert {:port_out, :b, :o} in obs
    assert {:edge, {:a, :o}, {:b, :i}} in obs

    # 2 nodes × 2 ports each + 1 edge = 5
    assert length(obs) == 5
  end

  @tag :tmp_dir
  test "report defaults to zero reached", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "a.bloccs"), tmp_node("a", "i", "X@1", "o", "Y@1"))

    File.write!(Path.join(tmp, "n.bloccs"), ~S"""
    [network]
    id = "covdemo"
    version = "0.1.0"

    [nodes]
    a = { use = "a.bloccs" }
    """)

    {:ok, network} = Parser.parse_network(Path.join(tmp, "n.bloccs"))
    %{obligations: all, reached: [], unreached: un} = Coverage.report(network)
    assert length(un) == length(all)
  end

  @tag :tmp_dir
  test "report subtracts reached obligations", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "a.bloccs"), tmp_node("a", "i", "X@1", "o", "Y@1"))

    File.write!(Path.join(tmp, "n.bloccs"), ~S"""
    [network]
    id = "covdemo"
    version = "0.1.0"

    [nodes]
    a = { use = "a.bloccs" }
    """)

    {:ok, network} = Parser.parse_network(Path.join(tmp, "n.bloccs"))
    reached = [{:port_in, :a, :i}]
    %{unreached: un} = Coverage.report(network, reached)
    refute {:port_in, :a, :i} in un
  end

  @tag :tmp_dir
  test "render produces a non-empty summary", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "a.bloccs"), tmp_node("a", "i", "X@1", "o", "Y@1"))

    File.write!(Path.join(tmp, "n.bloccs"), ~S"""
    [network]
    id = "covdemo"
    version = "0.1.0"

    [nodes]
    a = { use = "a.bloccs" }
    """)

    {:ok, network} = Parser.parse_network(Path.join(tmp, "n.bloccs"))
    rendered = Coverage.render(network, Coverage.report(network))
    assert rendered =~ "covdemo"
    assert rendered =~ "Total obligations:"
    assert rendered =~ "v0.4+"
  end
end
