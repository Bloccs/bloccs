defmodule Bloccs.Integration.EventsTest do
  @moduledoc """
  The headline v0.1 assertion: parse → validate → compile → run the `events`
  sample network with mock HTTP/DB effects, observing messages emerge at the
  exposed output ports for the known, unknown, and rejected paths — plus
  idempotency and the per-node telemetry span.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Producer, Router, Validator}
  alias Bloccs.Effects.DB.Mock, as: MockDB
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP

  @network_path Path.join([
                  Path.expand("../../examples/events/networks", __DIR__),
                  "events.bloccs"
                ])

  setup_all do
    Bloccs.Schema.clear!()
    Events.Schemas.register()

    {:ok, network} = Parser.parse_network(@network_path)
    :ok = Validator.validate_network(network)
    {:ok, sup_module} = Compiler.compile_and_load(network)
    {:ok, _} = sup_module.start_link([])

    on_exit(fn ->
      try do
        Supervisor.stop(sup_module, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{network: network, supervisor: sup_module}
  end

  setup do
    MockHTTP.reset()
    MockDB.reset()
    Bloccs.Idempotency.reset()

    MockHTTP.stub("GET", "http://enrichment.local/lookup", fn _ ->
      %{"region" => "us-east"}
    end)

    MockHTTP.stub("POST", "http://hooks.local/notify", fn _ -> %{"ok" => true} end)

    :ok = subscribe_to_exposed_ports()
    :ok
  end

  test "known event fans out to persist + notify" do
    push(%{id: "evt-ok", type: "order.created", payload: %{"order_id" => 1}})

    assert_receive {:bloccs_sink, :events, :persist, :stored, stored}, 2_000
    assert stored.event_id == "evt-ok"
    assert stored.type == "order.created"
    assert is_integer(stored.id)

    assert_receive {:bloccs_sink, :events, :notify, :notified, notified}, 2_000
    assert notified.id == "evt-ok"
    assert notified.status == "sent"

    refute_receive {:bloccs_sink, :events, :deadletter, :recorded, _}, 200

    assert [{:events, _row}] = MockDB.inserts()
  end

  test "unknown type is dead-lettered (and skips persist + notify)" do
    push(%{id: "evt-dead", type: "subscription.canceled", payload: %{"sub_id" => 9}})

    assert_receive {:bloccs_sink, :events, :deadletter, :recorded, dead}, 2_000
    assert dead.event_id == "evt-dead"

    refute_receive {:bloccs_sink, :events, :persist, :stored, _}, 200
    refute_receive {:bloccs_sink, :events, :notify, :notified, _}, 200

    assert [{:deadletter, _row}] = MockDB.inserts()
  end

  test "malformed events are rejected before any sink fires" do
    # Not a map → fails inbound schema validation at the ingest port.
    push("definitely not a map")
    refute_any_sink()

    # Missing the required `payload` field → also fails schema validation.
    push(%{id: "evt-x", type: "order.created"})
    refute_any_sink()

    # Empty payload → passes schema, but the `validate` node rejects it in the
    # pure core, so no effect node ever runs.
    push(%{id: "evt-y", type: "order.created", payload: %{}})
    refute_any_sink()
  end

  test "a duplicate event id is processed only once" do
    event = %{id: "evt-dup", type: "order.created", payload: %{"order_id" => 7}}

    push(event)
    assert_receive {:bloccs_sink, :events, :persist, :stored, _}, 2_000
    assert_receive {:bloccs_sink, :events, :notify, :notified, _}, 2_000

    push(event)
    refute_receive {:bloccs_sink, :events, :persist, :stored, _}, 500
    refute_receive {:bloccs_sink, :events, :notify, :notified, _}, 200
  end

  test "the enrich node emits a telemetry stop event carrying its observability block" do
    test_pid = self()
    handler = "events-enrich-stop"

    :telemetry.attach(
      handler,
      [:bloccs, :node, :stop],
      fn _e, meas, meta, _ ->
        if meta.node == :enrich, do: send(test_pid, {:enrich_stop, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    push(%{id: "evt-tel", type: "user.created", payload: %{"user_id" => 3}})

    assert_receive {:enrich_stop, %{duration: dur}, %{outcome: :ok, observability: obs}}, 2_000
    assert is_integer(dur)
    assert obs.metrics == ["duration_ms"]

    # Drain the downstream fan-out so it doesn't bleed into the next test.
    assert_receive {:bloccs_sink, :events, :persist, :stored, _}, 2_000
    assert_receive {:bloccs_sink, :events, :notify, :notified, _}, 2_000
  end

  defp subscribe_to_exposed_ports do
    :ok = Router.register_sink(:events, :persist, :stored, self())
    :ok = Router.register_sink(:events, :notify, :notified, self())
    :ok = Router.register_sink(:events, :deadletter, :recorded, self())
    :ok
  end

  defp push(event) do
    producer = Router.producer_name(:events, :ingest, :received)
    Producer.push(producer, event)
  end

  defp refute_any_sink do
    refute_receive {:bloccs_sink, :events, :persist, :stored, _}, 200
    refute_receive {:bloccs_sink, :events, :notify, :notified, _}, 200
    refute_receive {:bloccs_sink, :events, :deadletter, :recorded, _}, 200
  end
end
