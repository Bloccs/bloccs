defmodule Bloccs.EffectsFacadeTest do
  @moduledoc """
  The facade layer dispatches a capability struct to whichever backend built
  it, so node source never names a concrete backend. These tests go through the
  facades (not the backend modules directly).
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Effects, Parser}
  alias Bloccs.Effects.{DB, HTTP, Random, Time}
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP

  @manifest ~S"""
  [node]
  id = "facade"
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
    %{caps: Effects.bind(node)}
  end

  test "HTTP facade dispatches to the bound backend", %{caps: caps} do
    MockHTTP.stub("POST", "https://api.example.com/v1/items", fn _ ->
      %{"id" => "item_facade"}
    end)

    assert {:ok, %{"id" => "item_facade"}} =
             HTTP.post(caps.http, "https://api.example.com/v1/items", %{})
  end

  test "HTTP facade still enforces the backend's allowlist", %{caps: caps} do
    assert_raise Bloccs.Effects.Denied, ~r/allowlist/, fn ->
      HTTP.post(caps.http, "https://evil.example.com/", %{})
    end
  end

  test "DB facade dispatches and enforces scope", %{caps: caps} do
    assert {:ok, row} = DB.insert(caps.db, :items, name: "c")
    assert row.name == "c"

    assert_raise Bloccs.Effects.Denied, ~r/scope/, fn ->
      DB.insert(caps.db, :other, foo: 1)
    end
  end

  test "Time facade returns a DateTime", %{caps: caps} do
    assert %DateTime{} = Time.now(caps.time)
  end

  test "facade dispatch on an undeclared axis raises through the Denied stub", %{caps: caps} do
    # random not declared on this node → Denied.Stub installed
    assert_raise Bloccs.Effects.Denied, ~r/not declared/, fn ->
      Random.int(caps.random, 10)
    end
  end
end
