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

  alias Bloccs.{Parser, Runtime, Router, Schema}
  alias Broadway.Message

  @manifest_path Path.join([
                   Path.expand("../../examples/payments/nodes", __DIR__),
                   "charge_customer.bloccs"
                 ])

  defmodule StubRepo do
    def insert_all(source, entries, _opts) do
      send(Application.get_env(:bloccs, :real_test_pid), {:db_insert, source, entries})
      {length(entries), nil}
    end
  end

  setup do
    Schema.clear!()
    Payments.Schemas.register()
    Bloccs.Idempotency.reset()

    # Select the REAL adapters via config (this is the production switch).
    adapter = fn req ->
      {req, Req.Response.new(status: 200, body: %{"id" => "ch_live", "status" => "succeeded"})}
    end

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

    {:ok, manifest} = Parser.parse_node(@manifest_path)

    cfg = %Runtime.Config{
      manifest: manifest,
      network_id: :real_demo,
      local_id: :charge,
      in_port: :charge_requested
    }

    Router.register(:real_demo, [])
    Router.register_sink(:real_demo, :charge, :charge_completed, self())

    %{cfg: cfg}
  end

  defp msg(data),
    do: %Message{data: data, metadata: %{}, acknowledger: {Bloccs.Producer.Acknowledger, :x, :x}}

  test "charge node runs the real Req + Ecto adapters via config and emits charge_completed",
       %{cfg: cfg} do
    payload = %{
      customer_id: "cus_real",
      amount_cents: 4200,
      currency: "USD",
      request_id: "req_real_1"
    }

    result = Runtime.process(msg(payload), cfg)
    refute match?(%Message{status: {:failed, _}}, result)

    # Real HTTP.Req adapter returned the stubbed Stripe success → emit fired.
    assert_receive {:bloccs_sink, :real_demo, :charge, :charge_completed,
                    %{customer_id: "cus_real", stripe_id: "ch_live", amount_cents: 4200}}

    # Real DB.Ecto adapter dispatched a schemaless insert_all to the repo.
    assert_receive {:db_insert, "charges", [%{customer_id: "cus_real", stripe_id: "ch_live"}]}
  end

  test "the real HTTP adapter still enforces the declared allowlist", %{cfg: cfg} do
    # charge_customer declares only api.stripe.com; point the impl elsewhere is
    # not possible from here, so instead assert a disallowed host is denied at
    # the adapter level (same Allowlist the live node uses).
    cap = Bloccs.Effects.HTTP.Req.new(%{allow: ["api.stripe.com"], methods: ["POST"]})

    assert_raise Bloccs.Effects.Denied, ~r/allowlist/, fn ->
      Bloccs.Effects.HTTP.post(cap, "https://evil.example.com/", %{})
    end

    _ = cfg
  end
end
