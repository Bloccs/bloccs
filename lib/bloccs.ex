defmodule Bloccs do
  @moduledoc """
  A typed declarative IR for Agentic Computation Graphs (ACGs) that compiles
  to a Broadway supervision tree on the BEAM.

  See `Bloccs.Manifest.Node`, `Bloccs.Manifest.Network`, `Bloccs.Parser`,
  `Bloccs.Validator`, and `Bloccs.Compiler` for the v0.1 surface.

  ## Request/response

  A network is otherwise fire-and-forget: a message goes in and side effects come
  out, but the caller gets nothing back. `call/4` and `cast/4` add request/response
  on top — without making the pipeline synchronous — by correlating a **reply**
  back to the caller via the message `trace_id` (`Bloccs.Lineage`, `Bloccs.Collector`).

  To use them, a terminal node must be declared `reply = true` in its manifest and
  emit the response on an out-port:

      [node]
      id = "price"
      kind = "transform"
      reply = true

  Then:

      {:ok, %{"total" => 42}} = Bloccs.call(:checkout, :request, %{"items" => [...]})

  `call/4` blocks until that node reports (or the timeout fires); `cast/4` returns
  the `trace_id` immediately and, with `send_result: true`, later messages the
  caller `{:bloccs_reply, trace_id, result}`. Both target an **exposed input port**
  (`[expose].in` in the network manifest). See `Bloccs.Collector` for limitations
  (first-wins aggregation; correlation does not survive a `[batch]`/`[join]`).
  """

  alias Bloccs.{Collector, Discovery, Lineage, Producer, Router}

  @type network_id :: atom()

  @doc """
  Returns the current bloccs library version.

  ## Examples

      iex> is_binary(Bloccs.version())
      true

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:bloccs, :vsn) |> to_string()
  end

  @doc """
  Push `payload` into the exposed input port `in_port` of running network
  `network_id` and **block** until a `reply = true` node responds.

  Returns `{:ok, reply_payload}` on success, or `{:error, reason}` where reason
  is one of:

  - `%Bloccs.EffectError{}` — a node on the request's trace failed terminally
    (bad inbound schema, the node raised / returned `{:error, _}` / timed out, or
    downstream delivery failed). The struct names the node and phase.
  - `:timeout` — no reply *and* no error within `:timeout` ms (default `5_000`),
    e.g. the request was filtered/dropped before reaching the reply node.
  - `:no_producer` | `:unknown_network` | `{:unknown_port, in_port}` — the
    request could not be admitted.

  The network keeps running asynchronously; only the calling process waits.
  """
  @spec call(network_id(), atom(), term(), keyword()) ::
          {:ok, term()} | {:error, Bloccs.EffectError.t() | term()}
  def call(network_id, in_port, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, producer, trace_id, meta} <- prepare(network_id, in_port),
         :ok <- Collector.register(network_id, trace_id, timeout),
         :ok <- push(producer, payload, meta) do
      Collector.await(network_id, trace_id)
    end
  end

  @doc """
  Push `payload` into the exposed input port `in_port` of running network
  `network_id` and return immediately with `{:ok, trace_id}` — the correlation id
  for the request.

  With `send_result: true`, the calling process is later sent
  `{:bloccs_reply, trace_id, result}` where `result` is `{:ok, payload}`,
  `{:error, %Bloccs.EffectError{}}`, or `{:error, :timeout}` (after `:timeout` ms,
  default `5_000`). Without it, the request is fire-and-forget and the returned
  `trace_id` is useful only for correlating telemetry / traces.
  """
  @spec cast(network_id(), atom(), term(), keyword()) ::
          {:ok, Lineage.id()} | {:error, term()}
  def cast(network_id, in_port, payload, opts \\ []) do
    with {:ok, producer, trace_id, meta} <- prepare(network_id, in_port) do
      if Keyword.get(opts, :send_result, false) do
        Collector.register_async(network_id, trace_id, self(), Keyword.get(opts, :timeout, 5_000))
      end

      case push(producer, payload, meta) do
        :ok -> {:ok, trace_id}
        {:error, _} = err -> err
      end
    end
  end

  # Resolve the entry producer for an exposed input port, and mint a fresh root
  # lineage whose trace_id is the correlation key the reply is matched on.
  defp prepare(network_id, in_port) do
    with {:ok, %{supervisor: sup}} <- lookup_network(network_id),
         {:ok, {node, port}} <- fetch_exposed_in(sup.__bloccs_introspect__(), in_port) do
      lineage = Lineage.root()
      producer = Router.producer_name(network_id, node, port)
      {:ok, producer, lineage.trace_id, %{Lineage.key() => lineage}}
    end
  end

  defp lookup_network(network_id) do
    case Discovery.lookup(network_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :unknown_network}
    end
  end

  defp fetch_exposed_in(%{expose: %{in: ins}}, in_port) do
    case Map.fetch(ins, in_port) do
      {:ok, {_node, _port} = endpoint} -> {:ok, endpoint}
      :error -> {:error, {:unknown_port, in_port}}
    end
  end

  defp push(producer, payload, meta) do
    case Producer.push(producer, payload, meta) do
      :ok -> :ok
      :no_producer -> {:error, :no_producer}
      {:error, _} = err -> err
    end
  end
end
