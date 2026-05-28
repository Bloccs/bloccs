defmodule Bloccs.EffectsTest do
  use ExUnit.Case, async: false

  alias Bloccs.{Effects, Parser}
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP
  alias Bloccs.Effects.DB.Mock, as: MockDB

  @manifest ~S"""
  [node]
  id = "charge"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  in_req = { schema = "Req@1" }

  [ports.out]
  out_ok = { schema = "Resp@1" }

  [effects]
  http = { allow = ["api.stripe.com"], methods = ["POST"] }
  db   = { allow = ["charges:insert"] }
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
    MockHTTP.stub("POST", "https://api.stripe.com/v1/charges", fn _req ->
      %{"id" => "ch_1", "status" => "succeeded"}
    end)

    caps = Effects.bind(node)

    assert {:ok, %{"id" => "ch_1"}} =
             MockHTTP.post(caps.http, "https://api.stripe.com/v1/charges", %{})
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
    assert {:ok, row} = MockDB.insert(caps.db, :charges, customer_id: "c", stripe_id: "s")
    assert row.customer_id == "c"

    assert_raise Bloccs.Effects.Denied, ~r/scope/, fn ->
      MockDB.insert(caps.db, :other_table, foo: 1)
    end
  end

  test "time effect", %{node: node} do
    caps = Effects.bind(node)
    assert %DateTime{} = Bloccs.Effects.Time.System.now(caps.time)
  end
end
