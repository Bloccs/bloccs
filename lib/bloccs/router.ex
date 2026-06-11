defmodule Bloccs.Router do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > Infrastructure called by compiler-generated pipelines — not part of the
  > stable user API. You drive this through manifests, not by calling it directly;
  > signatures may change between minor versions.

  Routes outbound emits from compiled nodes to the input producers of their
  downstream targets.

  The edge table is registered per-network via `register/2` at supervisor
  startup and stored in `:persistent_term` (read-heavy, written once per
  network boot), so it survives a Router restart and dispatch never blocks on
  this process. `dispatch/4` looks up the table and pushes each payload into
  every matching downstream producer via `Bloccs.Producer.push/2`. A push that fails
  (`:no_producer`, or a `{:error, :timeout}`) emits a `[:bloccs, :dispatch,
  :error]` telemetry event and is collected into `dispatch/4`'s return value so
  the caller can act on undelivered emits rather than silently dropping them.

  A `:sink` target is a process registered under a `Bloccs.Sink` name; sinks
  are typically test collectors (e.g. `Bloccs.Sink.Collector`) that record
  what reached an exposed output port.
  """

  use GenServer

  @type endpoint :: {atom(), atom()}
  @type edges :: [{endpoint(), [endpoint()]}]

  defstruct networks: %{}

  @doc "Start the router. Singleton, name-registered."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an edge table for a network. `edges` is a list of
  `{{from_node, from_port}, [{to_node, to_port}]}` pairs.

  Edge tables live in `:persistent_term` — written once per network boot,
  read on every dispatch without touching this process — so a Router restart
  cannot silently lose the routing of a running network. (Before this, routes
  lived in Router state: a restart meant every dispatch found zero targets and
  acked successfully into the void.)
  """
  @spec register(atom(), edges()) :: :ok
  def register(network_id, edges) when is_atom(network_id) and is_list(edges) do
    GenServer.call(__MODULE__, {:register, network_id, edges})
  end

  @doc """
  Remove a network's edge table (call when tearing a network down for good).
  """
  @spec unregister(atom()) :: :ok
  def unregister(network_id) when is_atom(network_id) do
    _ = :persistent_term.erase(edges_key(network_id))
    :ok
  end

  @doc """
  Dispatch a payload from `{network_id, from_node, from_port}` to every
  downstream producer. Also notifies any sink listener subscribed to the
  *source* endpoint — sinks observe what a port emitted, regardless of
  whether downstream edges exist.

  The optional `ctx` is the outbound `Bloccs.Lineage` context (`parents` +
  `trace_id`) computed by the runtime from the input message(s). A fresh
  `msg_id` is minted for the emitted message and carried to every downstream
  producer as metadata, so the message is trackable across the next hop. With no
  `ctx` (the `dispatch/4` form, or a direct call) the emit is stamped as its own
  root.

  Returns `:ok` when every push succeeded, or `{:error, failures}` where
  `failures` is a list of `{endpoint, reason}` for the edges whose push did not
  succeed. Each failure also emits a `[:bloccs, :dispatch, :error]` telemetry
  event before being collected.
  """
  @spec dispatch(atom(), atom(), atom(), term()) ::
          :ok | {:error, [{endpoint(), :no_producer | {:error, :timeout}}]}
  def dispatch(network_id, from_node, from_port, payload),
    do: dispatch(network_id, from_node, from_port, payload, Bloccs.Lineage.child(nil))

  @spec dispatch(atom(), atom(), atom(), term(), Bloccs.Lineage.ctx()) ::
          :ok | {:error, [{endpoint(), :no_producer | {:error, :timeout}}]}
  def dispatch(network_id, from_node, from_port, payload, ctx) do
    case :persistent_term.get(edges_key(network_id), :missing) do
      :missing ->
        # No edge table at all is a wiring/lifecycle bug (dispatch before
        # register, or after unregister) — fail loudly; an empty target list
        # for a known network is the normal terminal-node case.
        :telemetry.execute(
          [:bloccs, :dispatch, :error],
          %{},
          %{
            network: network_id,
            from_node: from_node,
            from_port: from_port,
            to_node: nil,
            to_port: nil,
            reason: :network_not_registered
          }
        )

        {:error, [{{from_node, from_port}, :network_not_registered}]}

      table ->
        targets = Map.get(table, {from_node, from_port}, [])
        do_dispatch(network_id, from_node, from_port, payload, ctx, targets)
    end
  end

  defp do_dispatch(network_id, from_node, from_port, payload, ctx, targets) do
    # One emitted message, possibly delivered to several edges: mint its lineage
    # once and carry it to every downstream producer (shared msg_id == one emit).
    lineage = Bloccs.Lineage.stamp(ctx)
    meta = %{Bloccs.Lineage.key() => lineage}

    # Trace/coverage signal: this out-port emitted, and each edge was traversed.
    # `:payload` carries an opt-in, bounded, redacted snapshot for observability
    # (nil unless `config :bloccs, :inspect, enabled: true` — see `Bloccs.Inspect`).
    # `:msg_id` / `:parents` / `:trace_id` carry the message's lineage.
    :telemetry.execute(
      [:bloccs, :emit],
      %{targets: length(targets)},
      %{
        network: network_id,
        from_node: from_node,
        from_port: from_port,
        targets: targets,
        payload: Bloccs.Inspect.capture(payload),
        msg_id: lineage.msg_id,
        parents: lineage.parents,
        trace_id: lineage.trace_id
      }
    )

    failures =
      Enum.reduce(targets, [], fn {to_node, to_port} = target, acc ->
        producer = producer_name(network_id, to_node, to_port)

        case Bloccs.Producer.push(producer, payload, meta) do
          :ok ->
            acc

          reason ->
            :telemetry.execute(
              [:bloccs, :dispatch, :error],
              %{},
              %{
                network: network_id,
                from_node: from_node,
                from_port: from_port,
                to_node: to_node,
                to_port: to_port,
                reason: reason
              }
            )

            [{target, reason} | acc]
        end
      end)

    case sink_lookup(network_id, from_node, from_port) do
      {:ok, pid} -> send(pid, {:bloccs_sink, network_id, from_node, from_port, payload})
      :error -> :ok
    end

    case failures do
      [] -> :ok
      failures -> {:error, Enum.reverse(failures)}
    end
  end

  @doc "Return targets for a given source port; used by tests."
  @spec lookup(atom(), atom(), atom()) :: [endpoint()]
  def lookup(network_id, from_node, from_port) do
    case :persistent_term.get(edges_key(network_id), :missing) do
      :missing -> []
      table -> Map.get(table, {from_node, from_port}, [])
    end
  end

  @doc "Register a sink listener (a pid) for a particular exposed port."
  @spec register_sink(atom(), atom(), atom(), pid()) :: :ok
  def register_sink(network_id, node_id, port, pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register_sink, network_id, node_id, port, pid})
  end

  @doc "Look up a sink. Returns `{:ok, pid}` or `:error`."
  def sink_lookup(network_id, node_id, port) do
    GenServer.call(__MODULE__, {:sink_lookup, network_id, node_id, port})
  end

  @doc """
  Compute the canonical producer process name for a `{network, node, port}`.
  The compiler hardcodes this so generated code and the router agree.
  """
  @spec producer_name(atom(), atom(), atom()) :: atom()
  def producer_name(network_id, node_id, port),
    do: :"bloccs_producer__#{network_id}__#{node_id}__#{port}"

  @doc "Return the canonical Broadway pipeline name for a `{network, node}`."
  @spec pipeline_name(atom(), atom()) :: atom()
  def pipeline_name(network_id, node_id),
    do: :"bloccs_pipeline__#{network_id}__#{node_id}"

  # ---------------- GenServer impl ----------------

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:register, network_id, edges}, _from, state) do
    table = build_table(edges)

    # Writes still serialize through this process (registration order stays
    # deterministic), but the table itself lives in persistent_term: re-putting
    # an identical table on a supervisor restart is a no-op, and Router state
    # holds only sink registrations afterwards.
    if :persistent_term.get(edges_key(network_id), :missing) != table do
      :persistent_term.put(edges_key(network_id), table)
    end

    {:reply, :ok, state}
  end

  def handle_call({:register_sink, network_id, node, port, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, Map.put(state, {:sink, network_id, node, port}, pid)}
  end

  def handle_call({:sink_lookup, network_id, node, port}, _from, state) do
    case Map.fetch(state, {:sink, network_id, node, port}) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      state
      |> Enum.reject(fn
        {{:sink, _, _, _}, ^pid} -> true
        _ -> false
      end)
      |> Map.new()

    {:noreply, state}
  end

  defp build_table(edges) do
    Enum.reduce(edges, %{}, fn {from, tos}, acc ->
      Map.update(acc, from, tos, &(&1 ++ tos))
    end)
  end

  defp edges_key(network_id), do: {__MODULE__, :edges, network_id}
end
