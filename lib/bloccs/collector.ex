defmodule Bloccs.Collector do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > The rendezvous behind `Bloccs.call/4` and `Bloccs.cast/4`. You drive this
  > through those two functions and a `reply = true` node, not by calling it
  > directly.

  Correlates a network's **reply** (or terminal **error**) back to the caller
  that injected the request.

  bloccs is otherwise fire-and-forget: `Bloccs.Producer.push/3` returns once a
  message is *admitted*, not once it is *processed*. The collector restores
  request/response on top of that — without making the pipeline synchronous — by
  reusing the per-message `trace_id` (`Bloccs.Lineage`) as the correlation key:

    1. `Bloccs.call/4` mints a root lineage (trace_id `T`), **registers** `T` here
       (so the collector is expecting it *before* the request can fail or reply),
       then pushes the request.
    2. The request flows through the graph; `trace_id` rides unchanged on every
       1:1 / split / router hop.
    3. A node declared `reply = true` reports its emitted payload here (an
       `{:ok, payload}` result); a node that fails terminally on the trace reports
       an `{:error, %Bloccs.EffectError{}}` result. Both are keyed by `T`.
    4. The collector matches `T` and hands the result to the blocked caller.

  A single process serves every running network; entries are keyed by
  `{network_id, trace_id}` so ids never collide across networks.

  ## Register-before-push (no races, no fire-and-forget overhead)

  `call/4` / `cast/4` register **synchronously before** pushing, so by the time
  the message can produce a reply or error, the collector is already expecting it.
  A result for a key that is **not** registered is dropped immediately (not
  buffered) — so a plain `Bloccs.Producer.push/3` or a `reply = true` node used in
  a fire-and-forget pipeline costs the collector nothing beyond an O(1) drop. A
  result that arrives before the caller blocks on `await/2` is held (`:ready`)
  until claimed. The timeout is enforced collector-side, so a late result can
  never crash a timed-out caller.

  ## Observability

  The request/response lifecycle is observable two ways (for the dashboard / your
  own handlers):

  - **Telemetry** — `[:bloccs, :request, :start]` when a request registers and
    `[:bloccs, :request, :stop]` when it resolves (with `:outcome`
    `:reply | :error | :timeout`, a `:duration`, and the `%Bloccs.EffectError{}`
    under `:error` on a failure). See `Bloccs.Telemetry`.
  - **Snapshot** — `stats/0` returns the current in-flight request count, total
    and per network.

  ## Limitations (current milestone)

  - Aggregation is **first-wins**: the first result reported for a `trace_id` is
    the answer; later ones for the same id are dropped. Fan-out networks with
    several reply emits per request need an `:all` policy (later milestone).
  - A `[batch]`/`[join]` on the request path mints a fresh `trace_id`, breaking
    correlation — including error correlation. Keep the reply node on the
    request's 1:1 trace.
  """

  use GenServer

  alias Bloccs.{EffectError, Lineage}

  @type network_id :: atom()
  @type key :: {network_id(), Lineage.id()}
  @type result :: {:ok, term()} | {:error, EffectError.t()}

  # ---------- client API ----------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a blocking (`call/4`) request for `trace_id` on `network_id`, to be
  collected by `await/2`. Synchronous: returns once the collector is expecting
  the id, so the caller can push without racing the reply. The `timeout_ms`
  deadline is enforced collector-side.
  """
  @spec register(network_id(), Lineage.id(), timeout()) :: :ok
  def register(network_id, trace_id, timeout_ms) do
    GenServer.call(__MODULE__, {:register, {network_id, trace_id}, timeout_ms})
  end

  @doc """
  Register an async (`cast/4` with `send_result: true`) request: when the result
  for `trace_id` arrives, `pid` is sent `{:bloccs_reply, trace_id, result}` (a
  `{:ok, payload}` or `{:error, %Bloccs.EffectError{}}`), or
  `{:bloccs_reply, trace_id, {:error, :timeout}}` after `timeout_ms`.
  """
  @spec register_async(network_id(), Lineage.id(), pid(), timeout()) :: :ok
  def register_async(network_id, trace_id, pid, timeout_ms) do
    GenServer.call(__MODULE__, {:register_async, {network_id, trace_id}, pid, timeout_ms})
  end

  @doc """
  Block until the result for a previously `register/3`ed `trace_id` arrives, or
  its deadline fires. Returns the reported result (`{:ok, payload}` or
  `{:error, %Bloccs.EffectError{}}`), or `{:error, :timeout}`.
  """
  @spec await(network_id(), Lineage.id()) :: result() | {:error, :timeout}
  def await(network_id, trace_id) do
    GenServer.call(__MODULE__, {:await, {network_id, trace_id}}, :infinity)
  end

  @doc """
  Report a successful reply payload for `trace_id`. Called from the runtime for a
  `reply = true` node. Dropped if `trace_id` isn't registered; first report wins.
  """
  @spec report(network_id(), Lineage.id(), term()) :: :ok
  def report(network_id, trace_id, payload) do
    GenServer.cast(__MODULE__, {:report, {network_id, trace_id}, {:ok, payload}})
  end

  @doc """
  Report a terminal failure for `trace_id`. Called from the runtime when a node
  on the trace fails terminally. Dropped if `trace_id` isn't registered; first
  report wins (a reply already reported takes precedence).
  """
  @spec report_error(network_id(), Lineage.id(), EffectError.t()) :: :ok
  def report_error(network_id, trace_id, %EffectError{} = error) do
    GenServer.cast(__MODULE__, {:report, {network_id, trace_id}, {:error, error}})
  end

  @doc """
  A snapshot of in-flight request/response state: the total still awaiting a
  result, and a per-network breakdown. For observability (e.g. a dashboard gauge).
  """
  @spec stats() :: %{in_flight: non_neg_integer(), by_network: %{network_id() => pos_integer()}}
  def stats, do: GenServer.call(__MODULE__, :stats)

  # ---------- server ----------

  @impl true
  def init(_opts), do: {:ok, %{requests: %{}}}

  @impl true
  def handle_call({:register, key, timeout_ms}, _from, %{requests: reqs} = state) do
    tref = schedule_expire(key, timeout_ms)
    emit_start(key, :call)
    {:reply, :ok, put(state, reqs, key, new_slot(:pending, tref, :call, []))}
  end

  def handle_call({:register_async, key, pid, timeout_ms}, _from, %{requests: reqs} = state) do
    tref = schedule_expire(key, timeout_ms)
    emit_start(key, :cast)
    {:reply, :ok, put(state, reqs, key, new_slot(:async, tref, :cast, pid: pid))}
  end

  # `timeout()` includes :infinity, which Process.send_after rejects with an
  # ArgumentError — inside handle_call that would kill the collector and with
  # it every in-flight request across all networks. No deadline, no timer.
  defp schedule_expire(_key, :infinity), do: nil

  defp schedule_expire(key, timeout_ms),
    do: Process.send_after(self(), {:expire, key}, timeout_ms)

  def handle_call(:stats, _from, %{requests: reqs} = state) do
    by_network = reqs |> Map.keys() |> Enum.frequencies_by(fn {nid, _tid} -> nid end)
    {:reply, %{in_flight: map_size(reqs), by_network: by_network}, state}
  end

  def handle_call({:await, key}, from, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{phase: :ready, result: result, timer: tref} = slot ->
        cancel(tref)
        emit_stop(key, slot, result)
        {:reply, result, drop(state, reqs, key)}

      %{phase: :pending} = slot ->
        {:noreply, put(state, reqs, key, Map.merge(slot, %{phase: :waiting, from: from}))}

      nil ->
        # Already expired (or never registered): treat as a timeout.
        {:reply, {:error, :timeout}, state}

      _already ->
        {:reply, {:error, :already_awaited}, state}
    end
  end

  @impl true
  def handle_cast({:report, key, result}, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{phase: :waiting, from: from, timer: tref} = slot ->
        cancel(tref)
        GenServer.reply(from, result)
        emit_stop(key, slot, result)
        {:noreply, drop(state, reqs, key)}

      %{phase: :async, pid: pid, timer: tref} = slot ->
        cancel(tref)
        send(pid, {:bloccs_reply, elem(key, 1), result})
        emit_stop(key, slot, result)
        {:noreply, drop(state, reqs, key)}

      %{phase: :pending} = slot ->
        # Result beat the awaiter; hold it until await/2 claims it (the deadline
        # timer keeps running and reaps it if the awaiter never comes).
        {:noreply,
         put(state, reqs, key, Map.put(slot, :phase, :ready) |> Map.put(:result, result))}

      _ ->
        # :ready (first-wins) or unregistered (fire-and-forget): drop.
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:expire, key}, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{phase: :waiting, from: from} = slot ->
        GenServer.reply(from, {:error, :timeout})
        emit_stop(key, slot, {:error, :timeout})

      %{phase: :async, pid: pid} = slot ->
        send(pid, {:bloccs_reply, elem(key, 1), {:error, :timeout}})
        emit_stop(key, slot, {:error, :timeout})

      %{} = slot ->
        # Registered but never awaited / a buffered result never claimed.
        emit_stop(key, slot, {:error, :timeout})

      nil ->
        :ok
    end

    {:noreply, drop(state, reqs, key)}
  end

  defp put(state, reqs, key, slot), do: %{state | requests: Map.put(reqs, key, slot)}
  defp drop(state, reqs, key), do: %{state | requests: Map.delete(reqs, key)}

  defp new_slot(phase, tref, mode, extra) do
    Enum.into(extra, %{phase: phase, mode: mode, timer: tref, started_at: System.monotonic_time()})
  end

  # ---------- telemetry ----------

  defp emit_start({network, trace}, mode) do
    :telemetry.execute(
      [:bloccs, :request, :start],
      %{system_time: System.system_time()},
      %{network: network, trace_id: trace, mode: mode}
    )
  end

  defp emit_stop({network, trace}, %{mode: mode, started_at: t0}, result) do
    :telemetry.execute(
      [:bloccs, :request, :stop],
      %{duration: System.monotonic_time() - t0},
      %{network: network, trace_id: trace, mode: mode}
      |> Map.merge(outcome_meta(result))
    )
  end

  defp outcome_meta({:ok, _}), do: %{outcome: :reply}
  defp outcome_meta({:error, %EffectError{} = e}), do: %{outcome: :error, error: e}
  defp outcome_meta({:error, :timeout}), do: %{outcome: :timeout}
  defp outcome_meta({:error, reason}), do: %{outcome: :error, error: reason}

  defp cancel(tref) when is_reference(tref) do
    _ = Process.cancel_timer(tref)
    :ok
  end

  defp cancel(_), do: :ok
end
