defmodule Bloccs.Router do
  @moduledoc """
  Routes outbound emits from compiled nodes to the input producers of their
  downstream targets.

  The edge table is registered per-network via `register/2` at supervisor
  startup. `dispatch/4` looks up the table and pushes each payload into every
  matching downstream producer via `Bloccs.Producer.push/2`.

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
  """
  @spec register(atom(), edges()) :: :ok
  def register(network_id, edges) when is_atom(network_id) and is_list(edges) do
    ensure_started()
    GenServer.call(__MODULE__, {:register, network_id, edges})
  end

  @doc """
  Dispatch a payload from `{network_id, from_node, from_port}` to every
  downstream producer. Also notifies any sink listener subscribed to the
  *source* endpoint — sinks observe what a port emitted, regardless of
  whether downstream edges exist.
  """
  @spec dispatch(atom(), atom(), atom(), term()) :: :ok
  def dispatch(network_id, from_node, from_port, payload) do
    ensure_started()

    targets = lookup(network_id, from_node, from_port)

    Enum.each(targets, fn {to_node, to_port} ->
      producer = producer_name(network_id, to_node, to_port)
      Bloccs.Producer.push(producer, payload)
    end)

    case sink_lookup(network_id, from_node, from_port) do
      {:ok, pid} -> send(pid, {:bloccs_sink, network_id, from_node, from_port, payload})
      :error -> :ok
    end

    :ok
  end

  @doc "Return targets for a given source port; used by tests."
  @spec lookup(atom(), atom(), atom()) :: [endpoint()]
  def lookup(network_id, from_node, from_port) do
    ensure_started()
    GenServer.call(__MODULE__, {:lookup, network_id, from_node, from_port})
  end

  @doc "Register a sink listener (a pid) for a particular exposed port."
  @spec register_sink(atom(), atom(), atom(), pid()) :: :ok
  def register_sink(network_id, node_id, port, pid) when is_pid(pid) do
    ensure_started()
    GenServer.call(__MODULE__, {:register_sink, network_id, node_id, port, pid})
  end

  @doc "Look up a sink. Returns `{:ok, pid}` or `:error`."
  def sink_lookup(network_id, node_id, port) do
    ensure_started()
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
    {:reply, :ok, Map.put(state, {:edges, network_id}, table)}
  end

  def handle_call({:lookup, network_id, from_node, from_port}, _from, state) do
    table = Map.get(state, {:edges, network_id}, %{})
    {:reply, Map.get(table, {from_node, from_port}, []), state}
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

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end
end
