defmodule Bloccs.Producer.Acknowledger do
  @moduledoc false
  @behaviour Broadway.Acknowledger

  @impl true
  def ack(_ack_ref, _successful, _failed), do: :ok
end

defmodule Bloccs.Producer do
  @moduledoc """
  A push-based GenStage producer used as the input port of a compiled node.

  Broadway names producer processes itself (e.g.
  `MyPipeline.Broadway.Producer_0`), so we additionally register a stable
  canonical name in `Bloccs.Registry` keyed by
  `{network_id, node_id, in_port}`. `push/2` resolves through the registry.
  """

  use GenStage

  @registry Bloccs.Registry

  @doc """
  Start a producer. The `:name` option is the canonical Registry key the
  router will push to.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @doc "Push a payload into the producer's buffer. Returns `:ok` or `:no_producer`."
  @spec push(atom(), term()) :: :ok | :no_producer
  def push(name, payload) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> GenStage.cast(pid, {:push, payload})
      [] -> :no_producer
    end
  end

  @impl GenStage
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    {:ok, _} = Registry.register(@registry, name, nil)

    {:producer,
     %{
       queue: :queue.new(),
       pending_demand: 0,
       name: name
     }}
  end

  @impl GenStage
  def handle_demand(incoming_demand, state) do
    deliver(%{state | pending_demand: state.pending_demand + incoming_demand})
  end

  @impl GenStage
  def handle_cast({:push, payload}, state) do
    deliver(%{state | queue: :queue.in(payload, state.queue)})
  end

  defp deliver(%{pending_demand: 0} = state), do: {:noreply, [], state}

  defp deliver(state) do
    {messages, q, demand} = take(state.queue, state.pending_demand, [])
    {:noreply, messages, %{state | queue: q, pending_demand: demand}}
  end

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue, 0}

  defp take(queue, demand, acc) do
    case :queue.out(queue) do
      {:empty, _} ->
        {Enum.reverse(acc), queue, demand}

      {{:value, payload}, rest} ->
        msg = %Broadway.Message{
          data: payload,
          acknowledger: {Bloccs.Producer.Acknowledger, :ignored, :ignored}
        }

        take(rest, demand - 1, [msg | acc])
    end
  end
end
