defmodule Bloccs.Introspect do
  @moduledoc """
  The read-only introspection API for running networks — the foundation a
  dashboard (e.g. `bloccs_web`) reads.

  It assembles a normalized `Bloccs.Introspect.Network` from data the runtime
  already holds: `Bloccs.Discovery` (which networks are up), the generated
  supervisor's `__bloccs_introspect__/0` (topology + node→impl + supervision),
  and each node's `__bloccs_manifest__/0` (ports, effects, kind). Liveness comes
  separately, from the `[:bloccs, …]` telemetry stream.
  """

  alias Bloccs.{Discovery, Producer, Router}
  alias Bloccs.Introspect.Network
  alias Bloccs.Manifest.{Effects, Node, Port}

  @doc "Summaries of every running network (id, version, counts, uptime)."
  @spec list_networks() :: [Network.summary()]
  def list_networks do
    Enum.map(Discovery.list(), fn entry ->
      intro = entry.supervisor.__bloccs_introspect__()

      %{
        id: entry.network_id,
        version: intro.version,
        node_count: length(intro.nodes),
        edge_count: length(intro.edges),
        started_at: entry.started_at,
        supervisor: entry.supervisor
      }
    end)
  end

  @doc "Full normalized topology for one running network."
  @spec network(atom()) :: {:ok, Network.t()} | {:error, :not_found}
  def network(network_id) do
    case Discovery.lookup(network_id) do
      {:ok, entry} -> {:ok, build(network_id, entry)}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  The input producers of a network (one per in-port), with their canonical name
  and whether the process is currently registered.
  """
  @spec producers(atom()) ::
          [%{node: atom(), port: atom(), name: atom(), alive?: boolean()}]
  def producers(network_id) do
    case network(network_id) do
      {:ok, %Network{nodes: nodes}} ->
        for node <- nodes, port <- node.ports_in do
          name = Router.producer_name(network_id, node.id, port.name)
          %{node: node.id, port: port.name, name: name, alive?: registered?(name)}
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Snapshot one producer's queue state (size / buffer / blocked / utilization) by
  its canonical name. Delegates to the safe `Bloccs.Producer.stats/1` accessor.
  """
  @spec producer_state(atom()) :: {:ok, Producer.stats()} | {:error, :not_found | :timeout}
  def producer_state(producer_name) do
    case Producer.stats(producer_name) do
      {:ok, stats} -> {:ok, stats}
      :no_producer -> {:error, :not_found}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  # ---------------- assembly ----------------

  defp build(network_id, entry) do
    intro = entry.supervisor.__bloccs_introspect__()

    %Network{
      id: network_id,
      version: intro.version,
      supervisor: entry.supervisor,
      started_at: entry.started_at,
      supervision: intro.supervision,
      expose: intro.expose,
      nodes: Enum.map(intro.nodes, &node_view/1),
      edges: edge_views(intro.edges)
    }
  end

  defp node_view({local_id, impl_module, concurrency}) do
    manifest = impl_module.__bloccs_manifest__()

    %{
      id: local_id,
      kind: manifest.kind,
      glyph: glyph(manifest),
      ports_in: ports(manifest.ports_in),
      ports_out: ports(manifest.ports_out),
      effects: Effects.declared(manifest.effects),
      concurrency: concurrency,
      doc: doc(manifest.doc),
      contract: contract(manifest.contract),
      config: config(manifest)
    }
  end

  defp ports(map) do
    Enum.map(map, fn {name, %Port{} = p} -> %{name: name, schema: p.schema, buffer: p.buffer} end)
  end

  # The node's implementation contract: which functions provide its logic (the
  # author's `pure_core` / `effect_shell`) plus the per-message policies. This is
  # what an observer needs to see "what code runs here" — and what a component
  # author exposes when shipping their own bloccs node.
  defp contract(c) do
    %{
      pure_core: ref(c.pure_core),
      effect_shell: ref(c.effect_shell),
      timeout_ms: c.timeout_ms,
      retry: c.retry,
      idempotency: c.idempotency
    }
  end

  defp ref(%{module: m, function: f, arity: a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp ref(_), do: nil

  # Primitive configuration declared on the node ([batch]/[join]/[rate]/[delay]).
  defp config(manifest) do
    %{
      batch: manifest.batch,
      join: manifest.join,
      rate: manifest.rate,
      delay_ms: manifest.delay_ms
    }
  end

  defp doc(nil), do: %{intent: nil, owner: nil}
  defp doc(%{intent: intent, owner: owner}), do: %{intent: intent, owner: owner}

  defp edge_views(edges) do
    Enum.flat_map(edges, fn {from, tos} ->
      Enum.map(tos, fn to -> %{from: from, to: to} end)
    end)
  end

  @doc """
  The canonical notation glyph for a node manifest. Lives here so the notation
  stays a property of the library, not invented by each viewer. Filter/merge are
  emergent (return shape / wiring) and not derivable from a single node manifest.
  """
  @spec glyph(Node.t()) :: Network.glyph()
  def glyph(%Node{} = m) do
    cond do
      m.kind == :source -> :source
      m.kind == :sink -> :sink
      m.batch != nil -> :batch
      m.join != nil -> :join
      m.rate != nil -> :throttle
      m.delay_ms != nil -> :delay
      m.kind == :router -> :split
      Effects.declared(m.effects) != [] -> :node_effect
      true -> :node
    end
  end

  defp registered?(name), do: match?([{_pid, _}], Registry.lookup(Bloccs.Registry, name))
end
