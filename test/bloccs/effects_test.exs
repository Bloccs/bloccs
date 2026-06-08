defmodule Bloccs.EffectsTest do
  use ExUnit.Case, async: false

  alias Bloccs.{Effects, Parser}
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP
  alias Bloccs.Effects.DB.Mock, as: MockDB

  @manifest ~S"""
  [node]
  id = "process"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  in_req = { schema = "Req@1" }

  [ports.out]
  out_ok = { schema = "Resp@1" }

  [effects]
  http = { allow = ["api.example.com"], methods = ["POST"] }
  db   = { allow = ["items:insert"] }
  time = "wall_clock"

  [contract]
  pure_core = "Bloccs.Stub.transform/2"
  effect_shell = "Bloccs.Stub.execute/2"
  """

  setup do
    {:ok, node} = Parser.parse_node_string(@manifest)
    MockHTTP.reset()
    MockDB.reset()
    %{node: node}
  end

  test "allowed HTTP call hits stub", %{node: node} do
    MockHTTP.stub("POST", "https://api.example.com/v1/items", fn _req ->
      %{"id" => "item_1", "status" => "ok"}
    end)

    caps = Effects.bind(node)

    assert {:ok, %{"id" => "item_1"}} =
             MockHTTP.post(caps.http, "https://api.example.com/v1/items", %{})
  end

  test "disallowed host is refused", %{node: node} do
    caps = Effects.bind(node)

    assert_raise Bloccs.Effects.Denied, ~r/allowlist/, fn ->
      MockHTTP.post(caps.http, "https://evil.example.com/", %{})
    end
  end

  test "undeclared axis on the node raises", %{node: node} do
    caps = Effects.bind(node)
    # `random` not declared on this node — stub installed
    assert_raise Bloccs.Effects.Denied, ~r/axis not declared/, fn ->
      Bloccs.Effects.Denied.Stub.int(caps.random, 10)
    end
  end

  test "DB insert is scoped", %{node: node} do
    caps = Effects.bind(node)
    assert {:ok, row} = MockDB.insert(caps.db, :items, name: "c", value: "s")
    assert row.name == "c"

    assert_raise Bloccs.Effects.Denied, ~r/scope/, fn ->
      MockDB.insert(caps.db, :other_table, foo: 1)
    end
  end

  describe "DB.Mock reads" do
    setup do
      MockDB.reset()
      cap = MockDB.new(%{allow: ["items:insert", "items:read"]})
      {:ok, _} = MockDB.insert(cap, :items, name: "a", group: "x")
      {:ok, %{id: id_b}} = MockDB.insert(cap, :items, name: "b", group: "x")
      {:ok, _} = MockDB.insert(cap, :items, name: "c", group: "y")
      %{cap: cap, id_b: id_b}
    end

    test "get/3 fetches by id as a string-keyed map", %{cap: cap, id_b: id_b} do
      assert {:ok, %{"name" => "b", "id" => ^id_b}} = MockDB.get(cap, :items, id_b)
    end

    test "get/3 returns nil for a missing id", %{cap: cap} do
      assert {:ok, nil} = MockDB.get(cap, :items, -1)
    end

    test "all/3 filters by ANDed equality, in insertion order", %{cap: cap} do
      assert {:ok, rows} = MockDB.all(cap, :items, %{"group" => "x"})
      assert Enum.map(rows, & &1["name"]) == ["a", "b"]
    end

    test "all/3 with an empty filter returns every row", %{cap: cap} do
      assert {:ok, rows} = MockDB.all(cap, :items, %{})
      assert length(rows) == 3
    end

    test "one/3 returns a single match, nil, or :multiple_results", %{cap: cap} do
      assert {:ok, %{"name" => "c"}} = MockDB.one(cap, :items, %{"group" => "y"})
      assert {:ok, nil} = MockDB.one(cap, :items, %{"group" => "none"})
      assert {:error, :multiple_results} = MockDB.one(cap, :items, %{"group" => "x"})
    end

    test "reads require a :read scope" do
      insert_only = MockDB.new(%{allow: ["items:insert"]})

      assert_raise Bloccs.Effects.Denied, ~r/items:read/, fn ->
        MockDB.all(insert_only, :items, %{})
      end
    end

    test "an undeclared db axis refuses reads through the facade" do
      stub = Bloccs.Effects.Denied.Stub.new(:undeclared)

      assert_raise Bloccs.Effects.Denied, ~r/axis not declared/, fn ->
        Bloccs.Effects.DB.all(stub, :items, %{})
      end
    end
  end

  test "time effect", %{node: node} do
    caps = Effects.bind(node)
    assert %DateTime{} = Bloccs.Effects.Time.System.now(caps.time)
  end
end
