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

  describe "DB.Mock mutations + transactions" do
    setup do
      MockDB.reset()

      cap =
        MockDB.new(%{
          allow: ~w(items:insert items:read items:update items:delete votes:insert votes:read)
        })

      {:ok, %{id: id}} = MockDB.insert(cap, :items, slug: "x", votes: 0)
      %{cap: cap, id: id}
    end

    test "update/4 sets literals and increments with {:inc, n}", %{cap: cap, id: id} do
      assert {:ok, 1} = MockDB.update(cap, :items, id, %{slug: "y", votes: {:inc, 1}})
      assert {:ok, %{"slug" => "y", "votes" => 1}} = MockDB.get(cap, :items, id)

      assert {:ok, 1} = MockDB.update(cap, :items, id, %{votes: {:inc, -1}})
      assert {:ok, %{"votes" => 0}} = MockDB.get(cap, :items, id)
    end

    test "update/4 returns a 0 count when no row matches", %{cap: cap} do
      assert {:ok, 0} = MockDB.update(cap, :items, -1, %{slug: "z"})
    end

    test "update/4 requires an :update scope", %{id: id} do
      read_only = MockDB.new(%{allow: ["items:read"]})

      assert_raise Bloccs.Effects.Denied, ~r/items:update/, fn ->
        MockDB.update(read_only, :items, id, %{slug: "z"})
      end
    end

    test "delete/3 removes by id and reports the count", %{cap: cap, id: id} do
      assert {:ok, 1} = MockDB.delete(cap, :items, id)
      assert {:ok, nil} = MockDB.get(cap, :items, id)
      assert {:ok, 0} = MockDB.delete(cap, :items, id)
    end

    test "transaction/2 (closure) commits an atomic insert + counter increment", %{
      cap: cap,
      id: id
    } do
      assert {:ok, :counted} =
               MockDB.transaction(cap, fn db ->
                 {:ok, _} = MockDB.insert(db, :votes, item: id, who: "a")
                 {:ok, 1} = MockDB.update(db, :items, id, %{votes: {:inc, 1}})
                 {:ok, :counted}
               end)

      assert {:ok, %{"votes" => 1}} = MockDB.get(cap, :items, id)
      assert {:ok, [_one]} = MockDB.all(cap, :votes, %{})
    end

    test "transaction/2 rolls back every write when the body returns {:error, _}", %{
      cap: cap,
      id: id
    } do
      assert {:error, :nope} =
               MockDB.transaction(cap, fn db ->
                 {:ok, _} = MockDB.insert(db, :votes, item: id, who: "b")
                 {:ok, 1} = MockDB.update(db, :items, id, %{votes: {:inc, 1}})
                 {:error, :nope}
               end)

      # Both the vote insert and the counter increment were undone.
      assert {:ok, []} = MockDB.all(cap, :votes, %{})
      assert {:ok, %{"votes" => 0}} = MockDB.get(cap, :items, id)
    end

    test "transaction/2 rolls back when the body raises", %{cap: cap, id: id} do
      assert_raise RuntimeError, fn ->
        MockDB.transaction(cap, fn db ->
          {:ok, _} = MockDB.insert(db, :votes, item: id, who: "c")
          raise "boom"
        end)
      end

      assert {:ok, []} = MockDB.all(cap, :votes, %{})
    end

    test "transaction/2 (declarative ops) runs each op, returning per-op results", %{
      cap: cap,
      id: id
    } do
      # each op's result is unwrapped: the inserted row, then the update count.
      assert {:ok, [%{} = _vote, 1]} =
               MockDB.transaction(cap, [
                 {:insert, :votes, [item: id, who: "d"]},
                 {:update, :items, id, %{votes: {:inc, 1}}}
               ])

      assert {:ok, %{"votes" => 1}} = MockDB.get(cap, :items, id)
    end
  end

  test "time effect", %{node: node} do
    caps = Effects.bind(node)
    assert %DateTime{} = Bloccs.Effects.Time.System.now(caps.time)
  end
end
