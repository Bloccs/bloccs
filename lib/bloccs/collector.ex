defmodule Bloccs.Collector do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > The rendezvous behind `Bloccs.call/4` and `Bloccs.cast/4`. You drive this
  > through those two functions and a `reply = true` node, not by calling it
  > directly.

  Correlates a network's **reply** back to the caller that injected the request.

  bloccs is otherwise fire-and-forget: `Bloccs.Producer.push/3` returns once the
  message is *admitted*, not once it is *processed*. The collector restores
  request/response on top of that — without making the pipeline itself
  synchronous — by reusing the per-message `trace_id`
  (`Bloccs.Lineage`) as the correlation key:

    1. `Bloccs.call/4` mints a root lineage (trace_id `T`) and pushes the request.
    2. The request flows through the graph; `trace_id` rides unchanged on every
       1:1 / split / router hop (a `[batch]`/`[join]` mints a fresh trace, so
       reply correlation does **not** survive a fan-in — see "Limitations").
    3. A node declared `reply = true` reports each emitted payload here, keyed by
       the incoming message's `trace_id`.
    4. The collector matches `T` and replies to the blocked caller.

  A single process serves every running network; entries are keyed by
  `{network_id, trace_id}` so ids never collide across networks.

  ## Ordering / races

  `call/4` pushes **before** it awaits, so a reply can arrive before the waiter
  registers. Both orders are safe: a report with no waiter is **buffered**
  (`:ready`) until the matching `await/3` claims it; a waiter with no report yet
  blocks until the report arrives or the deadline fires. The collector — not the
  caller — enforces the timeout (the client `GenServer.call/3` uses `:infinity`),
  so a late report can never crash a timed-out caller.

  ## Limitations (M1)

  - Aggregation is **first-wins**: the first reported payload for a `trace_id` is
    the result; later ones for the same id are dropped. Fan-out networks with
    several reply emits per request need the `:all` policy (later milestone).
  - A `[batch]`/`[join]` on the request path mints a fresh `trace_id`, breaking
    correlation. Keep the reply node on the request's 1:1 trace for now.
  - Errors are not yet routed here as data; a failed request surfaces only as a
    `call/4` timeout. Typed error ports (error-as-data) are the next milestone.
  """

  use GenServer

  alias Bloccs.Lineage

  # How long a buffered (:ready) report with no waiter is retained before it is
  # discarded — bounds memory when a `cast/4` reply is never collected.
  @ready_ttl_ms 30_000

  @type network_id :: atom()
  @type key :: {network_id(), Lineage.id()}

  # ---------- client API ----------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Block until the reply for `trace_id` on `network_id` arrives, or `timeout_ms`
  elapses. Returns `{:ok, payload}` or `{:error, :timeout}`. The timeout is
  enforced collector-side, so the call itself never raises.
  """
  @spec await(network_id(), Lineage.id(), timeout()) :: {:ok, term()} | {:error, :timeout}
  def await(network_id, trace_id, timeout_ms) do
    GenServer.call(__MODULE__, {:await, {network_id, trace_id}, timeout_ms}, :infinity)
  end

  @doc """
  Register an async waiter: when the reply for `trace_id` arrives, `pid` is sent
  `{:bloccs_reply, trace_id, {:ok, payload}}` (or `{:error, :timeout}` after
  `timeout_ms`). Used by `Bloccs.cast/4` with `send_result: true`.
  """
  @spec expect_async(network_id(), Lineage.id(), pid(), timeout()) :: :ok
  def expect_async(network_id, trace_id, pid, timeout_ms) do
    GenServer.cast(__MODULE__, {:expect_async, {network_id, trace_id}, pid, timeout_ms})
  end

  @doc """
  Report a reply payload for `trace_id` on `network_id`. Called from the runtime
  for a `reply = true` node. Non-blocking; the first report for a key wins.
  """
  @spec report(network_id(), Lineage.id(), term()) :: :ok
  def report(network_id, trace_id, payload) do
    GenServer.cast(__MODULE__, {:report, {network_id, trace_id}, payload})
  end

  # ---------- server ----------

  @impl true
  def init(_opts), do: {:ok, %{requests: %{}}}

  @impl true
  def handle_call({:await, key, timeout_ms}, from, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{state: :ready, value: value, timer: tref} ->
        cancel(tref)
        {:reply, {:ok, value}, %{state | requests: Map.delete(reqs, key)}}

      nil ->
        tref = Process.send_after(self(), {:expire, key}, timeout_ms)
        entry = %{state: :waiting, from: from, timer: tref}
        {:noreply, %{state | requests: Map.put(reqs, key, entry)}}

      _busy ->
        {:reply, {:error, :already_awaited}, state}
    end
  end

  @impl true
  def handle_cast({:report, key, payload}, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{state: :waiting, from: from, timer: tref} ->
        cancel(tref)
        GenServer.reply(from, {:ok, payload})
        {:noreply, %{state | requests: Map.delete(reqs, key)}}

      %{state: :async, pid: pid, timer: tref} ->
        cancel(tref)
        send(pid, {:bloccs_reply, elem(key, 1), {:ok, payload}})
        {:noreply, %{state | requests: Map.delete(reqs, key)}}

      %{state: :ready} ->
        # First report already buffered; first-wins, ignore later ones.
        {:noreply, state}

      nil ->
        tref = Process.send_after(self(), {:expire, key}, @ready_ttl_ms)
        entry = %{state: :ready, value: payload, timer: tref}
        {:noreply, %{state | requests: Map.put(reqs, key, entry)}}
    end
  end

  def handle_cast({:expect_async, key, pid, timeout_ms}, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{state: :ready, value: value, timer: tref} ->
        cancel(tref)
        send(pid, {:bloccs_reply, elem(key, 1), {:ok, value}})
        {:noreply, %{state | requests: Map.delete(reqs, key)}}

      nil ->
        tref = Process.send_after(self(), {:expire, key}, timeout_ms)
        entry = %{state: :async, pid: pid, timer: tref}
        {:noreply, %{state | requests: Map.put(reqs, key, entry)}}

      _busy ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:expire, key}, %{requests: reqs} = state) do
    case Map.get(reqs, key) do
      %{state: :waiting, from: from} -> GenServer.reply(from, {:error, :timeout})
      %{state: :async, pid: pid} -> send(pid, {:bloccs_reply, elem(key, 1), {:error, :timeout}})
      _ -> :ok
    end

    {:noreply, %{state | requests: Map.delete(reqs, key)}}
  end

  defp cancel(tref) when is_reference(tref) do
    _ = Process.cancel_timer(tref)
    :ok
  end

  defp cancel(_), do: :ok
end
