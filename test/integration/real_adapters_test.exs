defmodule Bloccs.Integration.RealAdaptersTest do
  @moduledoc """
  Proves the *real* adapters (HTTP.Req, DB.Ecto) run end-to-end through the live
  execution core — `Bloccs.Runtime.process/2`, the exact path every compiled
  Broadway pipeline calls — selected purely via config, with no node-source
  changes. A fake Req transport and a stub repo stand in for the network/DB so
  the test is hermetic, but the bloccs code path is fully real: facade dispatch,
  allowlist + scope enforcement, emit, and router dispatch.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Parser, Router, Runtime, Schema}
  alias Broadway.Message

  @nodes_dir Path.expand("../../examples/events/nodes", __DIR__)

  defmodule StubRepo do
    def insert_all(source, entries, _opts) do
      send(Application.get_env(:bloccs, :real_test_pid), {:db_insert, source, entries})
      {length(entries), nil}
    end
  end

  setup do
    Schema.clear!()
    Events.Schemas.register()
    Bloccs.Idempotency.reset()

    # The real HTTP.Req adapter, but with a fake transport returning a canned
    # enrichment body — so no socket is opened.
    adapter = fn req ->
      {req, Req.Response.new(status: 200, body: %{"region" => "us-east"})}
    end

    # Select the REAL adapters via config (this is the production switch).
    Application.put_env(:bloccs, :effect_backends,
      http: Bloccs.Effects.HTTP.Req,
      db: Bloccs.Effects.DB.Ecto
    )

    Application.put_env(:bloccs, Bloccs.Effects.HTTP.Req, req_options: [adapter: adapter])
    Application.put_env(:bloccs, Bloccs.Effects.DB.Ecto, repo: StubRepo)
    Application.put_env(:bloccs, :real_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:bloccs, :effect_backends)
      Application.delete_env(:bloccs, Bloccs.Effects.HTTP.Req)
      Application.delete_env(:bloccs, Bloccs.Effects.DB.Ecto)
      Application.delete_env(:bloccs, :real_test_pid)
      Schema.clear!()
      Bloccs.Idempotency.reset()
    end)

    Router.register(:real_demo, [])
    :ok
  end

  defp cfg(node_file, local_id, in_port) do
    {:ok, manifest} = Parser.parse_node(Path.join(@nodes_dir, node_file))

    %Runtime.Config{
      manifest: manifest,
      network_id: :real_demo,
      local_id: local_id,
      in_port: in_port
    }
  end

  defp msg(data),
    do: %Message{data: data, metadata: %{}, acknowledger: {Bloccs.Producer.Acknowledger, :x, :x}}

  test "the enrich node runs the real Req adapter via config and emits enriched" do
    cfg = cfg("enrich.bloccs", :enrich, :valid)
    Router.register_sink(:real_demo, :enrich, :enriched, self())

    payload = %{id: "evt-real", type: "order.created", payload: %{"order_id" => 1}}

    result = Runtime.process(msg(payload), cfg)
    refute match?(%Message{status: {:failed, _}}, result)

    assert_receive {:bloccs_sink, :real_demo, :enrich, :enriched,
                    %{id: "evt-real", enrichment: %{"region" => "us-east"}}}
  end

  test "the persist node runs the real Ecto adapter via config and inserts" do
    cfg = cfg("persist.bloccs", :persist, :event)
    Router.register_sink(:real_demo, :persist, :stored, self())

    payload = %{
      id: "evt-real",
      type: "order.created",
      payload: %{"order_id" => 1},
      enrichment: %{"region" => "us-east"}
    }

    result = Runtime.process(msg(payload), cfg)
    refute match?(%Message{status: {:failed, _}}, result)

    # Real DB.Ecto adapter dispatched a schemaless insert_all to the repo.
    assert_receive {:db_insert, "events", [%{event_id: "evt-real", type: "order.created"}]}
  end

  test "the real HTTP adapter still enforces the declared allowlist" do
    # enrich declares only enrichment.local; a disallowed host is denied at the
    # adapter level (same Allowlist the live node uses).
    cap = Bloccs.Effects.HTTP.Req.new(%{allow: ["enrichment.local"], methods: ["GET"]})

    assert_raise Bloccs.Effects.Denied, ~r/allowlist/, fn ->
      Bloccs.Effects.HTTP.get(cap, "https://evil.example.com/")
    end
  end
end
