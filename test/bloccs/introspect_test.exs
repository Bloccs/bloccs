defmodule Bloccs.IntrospectTest do
  @moduledoc """
  The read-only introspection API a dashboard reads: `Discovery` (which networks
  are up), `Introspect` (normalized topology + glyphs), and the safe
  `Producer.stats/1` queue accessor. Asserted against the real `events` network.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Discovery, Introspect, Parser, Producer, Validator}
  alias Bloccs.Introspect.Network
  alias Bloccs.Manifest.{Effects, Node}

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
    {:ok, sup_pid} = sup_module.start_link([])

    on_exit(fn ->
      try do
        Supervisor.stop(sup_module, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{supervisor: sup_module, supervisor_pid: sup_pid}
  end

  describe "Discovery" do
    test "lists the running network with its supervisor and start time", %{supervisor: sup} do
      entries = Discovery.list()
      entry = Enum.find(entries, &(&1.network_id == :events))

      assert entry
      assert entry.supervisor == sup
      assert is_pid(entry.pid)
      assert is_integer(entry.started_at)
    end

    test "lookup/1 returns the entry, :error for unknown ids" do
      assert {:ok, %{network_id: :events}} = Discovery.lookup(:events)
      assert :error = Discovery.lookup(:does_not_exist)
    end

    test "auto-cleans up when the supervisor stops" do
      # A throwaway second network: parse the same manifest under a fresh id so
      # the global :events supervisor (used by other tests) is untouched.
      {:ok, network} = Parser.parse_network(@network_path)
      network = %{network | id: "events_ephemeral"}
      {:ok, sup} = Compiler.compile_and_load(network)
      {:ok, _pid} = sup.start_link([])

      assert {:ok, _} = Discovery.lookup(:events_ephemeral)
      :ok = Supervisor.stop(sup, :normal, 5_000)
      # Registry cleanup is async on process exit; give it a beat.
      Process.sleep(50)
      assert :error = Discovery.lookup(:events_ephemeral)
    end
  end

  describe "Introspect.list_networks/0" do
    test "summarizes the events network (7 nodes, 5 edge entries)" do
      summary = Enum.find(Introspect.list_networks(), &(&1.id == :events))

      assert summary.version == "0.1.0"
      assert summary.node_count == 7
      assert summary.edge_count == 5
      assert summary.supervisor == Bloccs.Compiled.Events.Supervisor
      assert is_integer(summary.started_at)
    end
  end

  describe "Introspect.network/1" do
    setup do
      {:ok, net} = Introspect.network(:events)
      %{net: net}
    end

    test "returns :not_found for an unknown network" do
      assert {:error, :not_found} = Introspect.network(:nope)
    end

    test "carries identity and supervision strategy", %{net: net} do
      assert %Network{id: :events, version: "0.1.0"} = net
      assert net.supervisor == Bloccs.Compiled.Events.Supervisor
      assert net.supervision.strategy == :rest_for_one
    end

    test "has all 7 nodes with the expected kinds and glyphs", %{net: net} do
      by_id = Map.new(net.nodes, &{&1.id, &1})

      assert map_size(by_id) == 7
      assert by_id[:ingest].kind == :source and by_id[:ingest].glyph == :source
      assert by_id[:validate].kind == :transform and by_id[:validate].glyph == :node
      assert by_id[:enrich].glyph == :node_effect and by_id[:enrich].effects == [:http]
      assert by_id[:route].kind == :router and by_id[:route].glyph == :split
      assert by_id[:persist].kind == :sink and by_id[:persist].glyph == :sink
    end

    test "exposes per-axis effect_detail (scopes / hosts) and the reply flag", %{net: net} do
      by_id = Map.new(net.nodes, &{&1.id, &1})

      # http nodes carry their allowed hosts + methods; db nodes their scopes.
      assert by_id[:enrich].effect_detail.http == %{allow: ["enrichment.local"], methods: ["GET"]}
      assert by_id[:persist].effect_detail.db == %{allow: ["events:insert"]}
      # an axis the node doesn't declare is nil.
      assert by_id[:validate].effect_detail.http == nil
      assert by_id[:validate].effect_detail.db == nil

      # reply defaults to false; this example has no reply node.
      assert Enum.all?(net.nodes, &(&1.reply == false))
    end

    test "exposes capability-linter status; nodes default to enforced", %{net: net} do
      # No node in the events example opts out, so all are linter-enforced with
      # no extra allows — an observer can trust the effect badges for every one.
      assert Enum.all?(net.nodes, &(&1.lint == %{enforced: true, allow: []}))
    end

    test "carries per-node concurrency from the deploy block", %{net: net} do
      by_id = Map.new(net.nodes, &{&1.id, &1})
      assert by_id[:enrich].concurrency == 4
      assert by_id[:persist].concurrency == 1
    end

    test "exposes ports with their schemas", %{net: net} do
      validate = Enum.find(net.nodes, &(&1.id == :validate))
      assert [%{name: :event}] = validate.ports_in
      assert [%{name: :valid, schema: schema}] = validate.ports_out
      assert is_binary(schema)
    end

    test "exposes each node's contract (the functions that run) and config", %{net: net} do
      enrich = Enum.find(net.nodes, &(&1.id == :enrich))
      assert enrich.contract.pure_core =~ ~r/\.transform\/2$/
      assert enrich.contract.effect_shell =~ ~r/\.execute\/2$/
      # the events `enrich` node declares a timeout + retry policy
      assert is_integer(enrich.contract.timeout_ms)
      assert is_map(enrich.config)
    end

    test "flattens the edge table into 6 endpoint pairs incl. the route fan-out", %{net: net} do
      assert length(net.edges) == 6

      froms = Enum.frequencies_by(net.edges, fn %{from: {node, _port}} -> node end)
      # route fans out three ways: known→persist, known→notify, unknown→deadletter
      assert froms[:route] == 3

      assert %{from: {:route, :known}, to: {:persist, :event}} in net.edges
      assert %{from: {:route, :known}, to: {:notify, :event}} in net.edges
      assert %{from: {:route, :unknown}, to: {:deadletter, :event}} in net.edges
    end

    test "carries the exposed in/out ports", %{net: net} do
      assert net.expose.in == %{webhook: {:ingest, :received}}
      assert net.expose.out[:stored] == {:persist, :stored}
    end
  end

  describe "Introspect.producers/1 and producer_state/1" do
    test "lists one producer per in-port, all alive" do
      producers = Introspect.producers(:events)

      # 7 nodes, each with exactly one in-port in the events network.
      assert length(producers) == 7
      assert Enum.all?(producers, & &1.alive?)

      ingest = Enum.find(producers, &(&1.node == :ingest))
      assert ingest.port == :received
      assert is_atom(ingest.name)
    end

    test "snapshots a producer's queue without :sys" do
      %{name: name} = Introspect.producers(:events) |> hd()

      assert {:ok, stats} = Introspect.producer_state(name)
      assert stats.size >= 0
      assert stats.buffer == :unbounded or is_integer(stats.buffer)
      assert stats.utilization >= 0.0
      assert is_integer(stats.pending_demand)
    end

    test "returns :not_found for an unregistered producer name" do
      assert {:error, :not_found} = Introspect.producer_state(:no_such_producer)
      assert :no_producer = Producer.stats(:no_such_producer)
    end
  end

  describe "glyph/1 mapping" do
    test "is total over every node manifest in the running network" do
      {:ok, net} = Introspect.network(:events)
      valid = ~w(node node_effect source sink split batch join throttle delay)a

      for node <- net.nodes do
        assert node.glyph in valid
      end
    end

    test "derives the glyph from kind/effects/primitive fields" do
      base = fn fields ->
        struct(Node, Map.merge(%{kind: :transform, effects: %Effects{}}, fields))
      end

      assert Introspect.glyph(base.(%{kind: :source})) == :source
      assert Introspect.glyph(base.(%{kind: :sink})) == :sink
      assert Introspect.glyph(base.(%{kind: :router})) == :split
      assert Introspect.glyph(base.(%{batch: %{size: 10}})) == :batch
      assert Introspect.glyph(base.(%{join: %{on: :id}})) == :join
      assert Introspect.glyph(base.(%{rate: %{per_second: 5}})) == :throttle
      assert Introspect.glyph(base.(%{delay_ms: 100})) == :delay
      assert Introspect.glyph(base.(%{effects: %Effects{http: %{}}})) == :node_effect
      assert Introspect.glyph(base.(%{})) == :node
    end
  end
end
