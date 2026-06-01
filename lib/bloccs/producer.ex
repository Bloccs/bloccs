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
  require Logger

  @registry Bloccs.Registry

  @doc """
  Start a producer. The `:name` option is the canonical Registry key the
  router will push to.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @doc """
  Push a payload into the producer's buffer. `meta` becomes the resulting
  `Broadway.Message`'s `:metadata` (the runtime uses `:bloccs_attempt` to track
  retries). Returns `:ok` or `:no_producer`.
  """
  @spec push(atom(), term(), map()) :: :ok | :no_producer
  def push(name, payload, meta \\ %{}) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> GenStage.cast(pid, {:push, payload, meta})
      [] -> :no_producer
    end
  end

  @doc """
  Re-enqueue a payload after `delay_ms`. Used by the runtime to schedule a
  retry with backoff; the timer lives in the (supervised) producer process.
  Returns `:ok` or `:no_producer`.
  """
  @spec push_after(atom(), term(), map(), non_neg_integer()) :: :ok | :no_producer
  def push_after(name, payload, meta, delay_ms) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] ->
        Process.send_after(pid, {:enqueue, payload, meta}, delay_ms)
        :ok

      [] ->
        :no_producer
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
       name: name,
       # nil = unbounded (the [ports.in].<port>.buffer manifest field)
       buffer: Keyword.get(opts, :buffer),
       size: 0
     }}
  end

  @impl GenStage
  def handle_demand(incoming_demand, state) do
    deliver(%{state | pending_demand: state.pending_demand + incoming_demand})
  end

  @impl GenStage
  def handle_cast({:push, payload, meta}, state) do
    enqueue(state, payload, meta)
  end

  @impl GenStage
  def handle_info({:enqueue, payload, meta}, state) do
    enqueue(state, payload, meta)
  end

  # Bounded enqueue. When the buffer is full we drop the *incoming* message
  # (push is fire-and-forget, so there's no upstream to back-pressure in v0.2)
  # and emit a telemetry event so operators can alarm on it. Real demand-based
  # back-pressure is future work.
  defp enqueue(state, payload, meta) do
    if full?(state) do
      :telemetry.execute(
        [:bloccs, :producer, :overflow],
        %{dropped: 1, size: state.size},
        %{name: state.name, buffer: state.buffer}
      )

      Logger.warning(
        "bloccs producer #{inspect(state.name)} buffer full (#{state.buffer}); dropping message"
      )

      {:noreply, [], state}
    else
      deliver(%{state | queue: :queue.in({payload, meta}, state.queue), size: state.size + 1})
    end
  end

  defp full?(%{buffer: nil}), do: false
  defp full?(%{buffer: max, size: size}), do: size >= max

  defp deliver(%{pending_demand: 0} = state), do: {:noreply, [], state}

  defp deliver(state) do
    {messages, q, demand} = take(state.queue, state.pending_demand, [])
    new_state = %{state | queue: q, pending_demand: demand, size: state.size - length(messages)}
    {:noreply, messages, new_state}
  end

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue, 0}

  defp take(queue, demand, acc) do
    case :queue.out(queue) do
      {:empty, _} ->
        {Enum.reverse(acc), queue, demand}

      {{:value, {payload, meta}}, rest} ->
        msg = %Broadway.Message{
          data: payload,
          metadata: meta,
          acknowledger: {Bloccs.Producer.Acknowledger, :ignored, :ignored}
        }

        take(rest, demand - 1, [msg | acc])
    end
  end
end
