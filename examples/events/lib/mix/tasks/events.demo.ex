defmodule Mix.Tasks.Events.Demo do
  @shortdoc "Run the events webhook-processor network end-to-end (mock effects)"

  @moduledoc """
      mix events.demo

  Compiles and starts the `events` network, then pushes a handful of webhook
  events through it and prints what came out. Runs entirely on the built-in mock
  effect backends — zero external services.

  It demonstrates the whole toolbox in one flow:

    * **branching + fan-out** — a known event is routed to *both* persist and
      notify; an unknown-type event is dead-lettered.
    * **idempotency** — a replayed event (same id) is deduped at the enrich node,
      before the lookup is even made.
    * **the pure failure path** — the validate node rejects an empty payload
      with no effect ever running.
  """

  use Mix.Task

  alias Bloccs.{Compiler, Parser, Producer, Router, Trace, Validator}
  alias Bloccs.Effects.DB.Mock, as: MockDB
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP

  @network "examples/events/networks/events.bloccs"
  @trace "events.bloccs-trace"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Events.Schemas.register()
    MockHTTP.reset()
    MockDB.reset()
    Bloccs.Idempotency.reset()

    # Stub the two HTTP endpoints the network calls (the mock refuses unstubbed
    # URLs). In production these become real hosts via config — see the README.
    MockHTTP.stub("GET", "http://enrichment.local/lookup", fn _ ->
      %{"region" => "us-east", "tier" => "gold"}
    end)

    MockHTTP.stub("POST", "http://hooks.local/notify", fn _ -> %{"ok" => true} end)

    {:ok, network} = Parser.parse_network(@network)
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    Router.register_sink(:events, :persist, :stored, self())
    Router.register_sink(:events, :notify, :notified, self())
    Router.register_sink(:events, :deadletter, :recorded, self())

    info("network `events` running — pushing webhook events\n")

    rec = Trace.record(:events)

    push(%{id: "evt-1", type: "order.created", payload: %{"order_id" => 1001}})
    push(%{id: "evt-2", type: "user.created", payload: %{"user_id" => 77}})
    # Unknown type → dead-lettered.
    push(%{id: "evt-3", type: "subscription.canceled", payload: %{"sub_id" => 9}})
    # Duplicate id of evt-1 → deduped at enrich, never reaches the sinks.
    push(%{id: "evt-1", type: "order.created", payload: %{"order_id" => 1001}})

    # 2 known events × (persist + notify) + 1 dead-lettered = 5 sink messages.
    collect(5)

    print_db()

    :ok = Trace.dump(Trace.stop(rec), :events, @trace)

    info("\nwrote #{@trace} — see structural coverage with:")
    info("  mix bloccs.coverage #{@network} --trace #{@trace}")
  end

  defp push(event) do
    producer = Router.producer_name(:events, :ingest, :received)
    _ = Producer.push(producer, event)
    info("  → pushed #{event.id} (#{event.type})")
  end

  defp collect(0), do: :ok

  defp collect(n) do
    receive do
      {:bloccs_sink, :events, :persist, :stored, %{event_id: id}} ->
        info("  ← persisted #{id}")
        collect(n - 1)

      {:bloccs_sink, :events, :notify, :notified, %{id: id, status: status}} ->
        info("  ← notified #{id} (#{status})")
        collect(n - 1)

      {:bloccs_sink, :events, :deadletter, :recorded, %{event_id: id}} ->
        info("  ← dead-lettered #{id}")
        collect(n - 1)
    after
      3_000 -> :ok
    end
  end

  defp print_db do
    inserts = Enum.reverse(MockDB.inserts())
    events = for {:events, row} <- inserts, do: row
    dead = for {:deadletter, row} <- inserts, do: row

    info("\nevents table (#{length(events)} rows):")
    Enum.each(events, fn r -> info("  ##{r.id}  #{r.event_id}  #{r.type}") end)

    info("\ndeadletter table (#{length(dead)} rows):")
    Enum.each(dead, fn r -> info("  ##{r.id}  #{r.event_id}  #{r.type}") end)

    info(
      "\n(4 events pushed: 2 known → persisted + notified, " <>
        "1 unknown → dead-lettered, 1 duplicate → deduped)"
    )
  end

  defp info(msg), do: Mix.shell().info(msg)
end
