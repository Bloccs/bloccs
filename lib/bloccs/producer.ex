defmodule Bloccs.Producer.Acknowledger do
  @moduledoc false
  @behaviour Broadway.Acknowledger

  @impl true
  def ack(_ack_ref, _successful, _failed), do: :ok
end

defmodule Bloccs.Producer do
  @moduledoc """
  A GenStage producer used as the input port of a compiled node.

  Broadway names producer processes itself (e.g.
  `MyPipeline.Broadway.Producer_0`), so we additionally register a stable
  canonical name in `Bloccs.Registry` keyed by `{network_id, node_id, in_port}`.
  `push/3` resolves through the registry.

  ## Back-pressure (v0.4)

  `push/3` is **synchronous** and bounded by the port's `buffer`. When the
  buffer is full the caller is *parked* — the call does not return until a
  downstream consumer drains space — so a slow consumer propagates back-pressure
  up the graph instead of dropping messages. An unbounded port (`buffer: nil`)
  never parks. The wait is bounded by `config :bloccs, :push_timeout` (default
  `:infinity`); on timeout `push/3` returns `{:error, :timeout}` rather than
  blocking forever.
  """

  use GenStage

  @registry Bloccs.Registry

  @doc """
  Start a producer. The `:name` option is the canonical Registry key the router
  pushes to; `:buffer` (optional) bounds the queue for back-pressure.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @doc """
  Push a payload into the producer, blocking if the buffer is full until space
  frees (see "Back-pressure"). `meta` becomes the `Broadway.Message`'s
  `:metadata` (the runtime uses `:bloccs_attempt` for retries).

  Returns `:ok`, `:no_producer` (name not registered), or `{:error, :timeout}`
  (waited past `:push_timeout`).
  """
  @spec push(atom(), term(), map()) :: :ok | :no_producer | {:error, :timeout}
  def push(name, payload, meta \\ %{}) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] ->
        try do
          GenStage.call(pid, {:push, payload, meta}, push_timeout())
        catch
          :exit, _ -> {:error, :timeout}
        end

      [] ->
        :no_producer
    end
  end

  @doc """
  Re-enqueue a payload after `delay_ms` (used by the runtime to schedule a retry
  with backoff; the timer lives in the supervised producer process). If the
  buffer is full when the timer fires, the enqueue is retried shortly rather
  than dropped. Returns `:ok` or `:no_producer`.
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
       # nil = no delay; otherwise hold each push this many ms (the [delay] field)
       delay: Keyword.get(opts, :delay),
       size: 0,
       # callers parked waiting for buffer space: {from, payload, meta}
       blocked: :queue.new()
     }}
  end

  @impl GenStage
  def handle_demand(incoming_demand, state) do
    {events, state} = drain(%{state | pending_demand: state.pending_demand + incoming_demand}, [])
    {:noreply, events, state}
  end

  @impl GenStage
  def handle_call({:push, payload, meta}, _from, %{delay: delay} = state)
      when is_integer(delay) and delay > 0 do
    # A delay node time-shifts each message: ack the push immediately and enqueue
    # it after `delay` via the existing timer path (which also respects the
    # buffer). The caller is not parked — delay shifts in time, it doesn't
    # back-pressure.
    Process.send_after(self(), {:enqueue, payload, meta}, delay)
    {:reply, :ok, [], state}
  end

  @impl GenStage
  def handle_call({:push, payload, meta}, from, state) do
    if room?(state) do
      {events, state} = state |> enqueue(payload, meta) |> drain([])
      {:reply, :ok, events, state}
    else
      # Park the caller until a consumer drains space — this is the back-pressure.
      :telemetry.execute(
        [:bloccs, :producer, :backpressure],
        %{size: state.size},
        %{name: state.name, buffer: state.buffer}
      )

      {:noreply, [], %{state | blocked: :queue.in({from, payload, meta}, state.blocked)}}
    end
  end

  @impl GenStage
  def handle_info({:enqueue, payload, meta}, state) do
    if room?(state) do
      {events, state} = state |> enqueue(payload, meta) |> drain([])
      {:noreply, events, state}
    else
      # No caller to park (timer-driven retry); try again shortly, don't drop.
      Process.send_after(self(), {:enqueue, payload, meta}, 25)
      {:noreply, [], state}
    end
  end

  # ---------------- internals ----------------

  defp room?(%{buffer: nil}), do: true
  defp room?(%{buffer: max, size: size}), do: size < max

  defp enqueue(state, payload, meta),
    do: %{state | queue: :queue.in({payload, meta}, state.queue), size: state.size + 1}

  # Deliver queued events to pending demand, then admit parked callers into the
  # freed space, repeating until neither makes progress.
  defp drain(state, acc) do
    {events, state} = deliver(state)
    {admitted, state} = admit_blocked(state)

    if events == [] and admitted == 0 do
      {acc, state}
    else
      drain(state, acc ++ events)
    end
  end

  defp deliver(%{pending_demand: 0} = state), do: {[], state}

  defp deliver(state) do
    {messages, q, demand} = take(state.queue, state.pending_demand, [])
    {messages, %{state | queue: q, pending_demand: demand, size: state.size - length(messages)}}
  end

  # Admit parked callers while there is buffer room, replying :ok to each.
  defp admit_blocked(state, count \\ 0) do
    if room?(state) do
      case :queue.out(state.blocked) do
        {:empty, _} ->
          {count, state}

        {{:value, {from, payload, meta}}, rest} ->
          GenStage.reply(from, :ok)
          admit_blocked(enqueue(%{state | blocked: rest}, payload, meta), count + 1)
      end
    else
      {count, state}
    end
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

  defp push_timeout, do: Application.get_env(:bloccs, :push_timeout, :infinity)
end
