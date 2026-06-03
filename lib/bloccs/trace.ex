defmodule Bloccs.Trace do
  @moduledoc """
  Records an execution trace of a running network by attaching to bloccs
  telemetry, and derives structural-coverage obligations from it.

  A recording observes two events, scoped to one network:

    * `[:bloccs, :node, :start]` — a message reached a node's in-port
      (`{:port_in, node, in_port}`).
    * `[:bloccs, :emit]` — a node emitted on an out-port
      (`{:port_out, node, out_port}`) and traversed each downstream edge
      (`{:edge, {from_node, from_port}, {to_node, to_port}}`).

  Those obligation shapes match `Bloccs.Coverage`, so a trace's `reached/1` set
  feeds `Bloccs.Coverage.report/2` directly.

  ## Recording

      rec = Bloccs.Trace.record(:payments)
      # ... feed messages through the network ...
      events = Bloccs.Trace.stop(rec)
      reached = Bloccs.Trace.reached(events)

  ## Persistence

  `dump/3` writes a `.bloccs-trace` file (JSON: `{network, events}`); `load/1`
  reads one back into the same event list. The format is deliberately legible —
  a trace is part of the IR you can inspect.
  """

  @events [
    [:bloccs, :node, :start],
    [:bloccs, :emit]
  ]

  @type endpoint :: {atom(), atom()}
  @type event ::
          {:port_in, atom(), atom()}
          | {:emit, atom(), atom(), [endpoint()]}

  @type recording :: %{network: atom(), handler: {module(), atom(), reference()}, agent: pid()}

  @doc "Start recording the trace for `network_id`. Returns a recording handle."
  def record(network_id) when is_atom(network_id) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    handler = {__MODULE__, network_id, make_ref()}

    :ok =
      :telemetry.attach_many(handler, @events, &__MODULE__.handle_event/4, %{
        agent: agent,
        network: network_id
      })

    %{network: network_id, handler: handler, agent: agent}
  end

  @doc "Stop recording; detach the handler and return the events in order."
  @spec stop(recording()) :: [event()]
  def stop(%{handler: handler, agent: agent}) do
    _ = :telemetry.detach(handler)
    events = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)
    events
  end

  @doc "Derive the set of reached `Bloccs.Coverage` obligations from events."
  @spec reached([event()]) :: [Bloccs.Coverage.obligation()]
  def reached(events) do
    events
    |> Enum.flat_map(fn
      {:port_in, node, port} ->
        [{:port_in, node, port}]

      {:emit, from, port, targets} ->
        [{:port_out, from, port} | Enum.map(targets, &{:edge, {from, port}, &1})]
    end)
    |> Enum.uniq()
  end

  @doc false
  def handle_event([:bloccs, :node, :start], _meas, meta, %{agent: agent, network: net}) do
    if meta[:network] == net do
      Agent.cast(agent, &[{:port_in, meta.node, meta.in_port} | &1])
    end
  end

  def handle_event([:bloccs, :emit], _meas, meta, %{agent: agent, network: net}) do
    if meta[:network] == net do
      Agent.cast(agent, &[{:emit, meta.from_node, meta.from_port, meta.targets} | &1])
    end
  end

  # ---------------- persistence (.bloccs-trace, JSON) ----------------

  @doc "Write `events` to a `.bloccs-trace` file (JSON) for network `network_id`."
  @spec dump([event()], atom(), Path.t()) :: :ok | {:error, term()}
  def dump(events, network_id, path) do
    doc = %{"network" => to_string(network_id), "events" => Enum.map(events, &encode_event/1)}

    with {:ok, json} <- Jason.encode(doc, pretty: true) do
      File.write(path, json)
    end
  end

  @doc "Load a `.bloccs-trace` file back into an event list."
  @spec load(Path.t()) :: {:ok, [event()]} | {:error, term()}
  def load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"events" => raw}} <- Jason.decode(text) do
      {:ok, Enum.map(raw, &decode_event/1)}
    end
  end

  defp encode_event({:port_in, node, port}) do
    %{"kind" => "port_in", "node" => to_string(node), "port" => to_string(port)}
  end

  defp encode_event({:emit, from, port, targets}) do
    %{
      "kind" => "emit",
      "node" => to_string(from),
      "port" => to_string(port),
      "targets" =>
        Enum.map(targets, fn {n, p} -> %{"node" => to_string(n), "port" => to_string(p)} end)
    }
  end

  defp decode_event(%{"kind" => "port_in", "node" => n, "port" => p}) do
    {:port_in, String.to_atom(n), String.to_atom(p)}
  end

  defp decode_event(%{"kind" => "emit", "node" => n, "port" => p, "targets" => ts}) do
    targets =
      Enum.map(ts, fn %{"node" => tn, "port" => tp} ->
        {String.to_atom(tn), String.to_atom(tp)}
      end)

    {:emit, String.to_atom(n), String.to_atom(p), targets}
  end
end
