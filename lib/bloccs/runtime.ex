defmodule Bloccs.Runtime do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > Infrastructure called by compiler-generated pipelines — not part of the
  > stable user API. You drive this through manifests, not by calling it directly;
  > signatures may change between minor versions.

  The execution core invoked from every compiler-emitted Broadway pipeline.

  Generated `handle_message/3` is a thin shim that builds a `Config` from the
  node's manifest plus its routing identity and calls `process/2`. Keeping the
  logic here — rather than templated into the codegen string — means inbound
  schema validation, timeout, retry, idempotency, and telemetry are
  unit-testable as ordinary library code instead of brittle generated text.

  The contract with a node implementation:

      pure_core(data, ctx)  :: {:ok, intermediate} | {:error, reason}
      effect_shell(mid, ctx) ::
          {:emit, port, payload}            # emit one message on one out-port
        | {:emit, [{port, payload}, ...]}   # split / multi-port: many messages at once
        | :drop                             # filter: consume the message, emit nothing
        | {:error, reason}

  A shell that returns `:drop` (or an empty emit list) is a **filter** — the
  message is acked and a `[:bloccs, :node, :dropped]` event is emitted, but
  nothing is dispatched downstream. A list of `{port, payload}` is a **split** —
  each pair is dispatched independently (a port may even appear more than once),
  so one invocation can fan a message out to several out-ports with distinct
  payloads. The bare `{:emit, port, payload}` form is the common single-emit
  case and is unchanged.
  """

  alias Bloccs.{Context, Effects, Idempotency, Manifest.Node, Pipeline, Producer, Retry, Router}
  alias Broadway.Message

  defmodule Config do
    @moduledoc """
    Everything the runtime needs to execute one node, derived from the node's
    manifest plus the `{network, node, in_port}` identity the compiler knows.
    """

    @type t :: %__MODULE__{
            manifest: Node.t(),
            network_id: atom(),
            local_id: atom(),
            in_port: atom()
          }

    @enforce_keys [:manifest, :network_id, :local_id, :in_port]
    defstruct [:manifest, :network_id, :local_id, :in_port]
  end

  @doc """
  Run one Broadway message through a node: validate inbound against the port
  schema, then `pure_core` → `effect_shell` → router dispatch.

  Returns the (possibly failed) `Broadway.Message`. A failed message carries a
  structured reason; it never reaches `pure_core`/`effect_shell` if inbound
  validation rejects it.
  """
  @spec process(Message.t(), Config.t()) :: Message.t()
  def process(%Message{} = msg, %Config{} = cfg) do
    meta = base_meta(cfg, msg)

    :telemetry.span([:bloccs, :node], meta, fn ->
      result = do_process(msg, cfg)
      {result, Map.merge(meta, outcome_meta(result))}
    end)
  end

  @doc """
  Prepare one message for an aggregate (batch) node: validate it against the
  in-port schema, then tag it for the batcher. An invalid message is failed
  immediately — it never enters the batch. Called from the generated
  `handle_message/3` of a batch node.
  """
  @spec batch_message(Message.t(), Config.t()) :: Message.t()
  def batch_message(%Message{} = msg, %Config{manifest: manifest, in_port: in_port}) do
    case Pipeline.validate_inbound(manifest, in_port, msg.data) do
      :ok -> Message.put_batcher(msg, :default)
      {:error, reason} -> Message.failed(msg, reason)
    end
  end

  @doc """
  Run an aggregate (batch) node over a batch of messages. `pure_core` receives
  the **list** of payloads (not a single one) and reduces them; `effect_shell`
  emits the aggregate result (or splits / drops, like any node). Returns the
  (possibly failed) messages — called from the generated `handle_batch/4`.

  Best-effort / at-least-once: a failed aggregate fails every message in the
  batch, and Broadway re-delivers per its config. The batch path does not run
  per-message retry / idempotency / timeout (the validator rejects those on a
  `[batch]` node).
  """
  @spec process_batch([Message.t()], Config.t()) :: [Message.t()]
  def process_batch(messages, %Config{manifest: manifest} = cfg) do
    # One in-port signal per batch, so coverage/trace mark the port reached.
    :telemetry.execute(
      [:bloccs, :node, :start],
      %{system_time: System.system_time()},
      batch_meta(cfg)
    )

    data = Enum.map(messages, & &1.data)
    # Fan-in: the aggregate's parents are every message in the batch.
    ctx = Bloccs.Lineage.merge(Enum.map(messages, &Bloccs.Lineage.of(&1.metadata)))

    case run_and_dispatch(manifest, data, cfg, ctx) do
      :ok ->
        messages

      :dropped ->
        :telemetry.execute([:bloccs, :node, :dropped], %{}, batch_meta(cfg))
        messages

      {:dispatch_failed, failures} ->
        :telemetry.execute(
          [:bloccs, :node, :dispatch_error],
          %{count: length(failures)},
          Map.put(batch_meta(cfg), :failures, failures)
        )

        Enum.map(messages, &Message.failed(&1, {:dispatch_failed, failures}))

      {:error, reason} ->
        Enum.map(messages, &Message.failed(&1, reason))
    end
  end

  @doc """
  Record one arrival at a join node's in-port. Once the arrival's correlation key
  (`[join].on`) has a payload on **every** in-port, the join contract runs over
  the correlated `%{port => payload}` map and the result is dispatched. A partial
  arrival is acked and held; a payload missing the correlation field fails the
  message. Called from the generated per-in-port `handle_message/3` of a join.
  """
  @spec join_arrival(Message.t(), Config.t(), atom()) :: Message.t()
  def join_arrival(%Message{} = msg, %Config{manifest: manifest} = cfg, port) do
    case Pipeline.validate_inbound(manifest, port, msg.data) do
      {:error, reason} ->
        Message.failed(msg, reason)

      :ok ->
        # Mark the in-port reached (coverage/trace) before correlating.
        :telemetry.execute(
          [:bloccs, :node, :start],
          %{system_time: System.system_time()},
          join_meta(cfg, port)
        )

        lineage = Bloccs.Lineage.of(msg.metadata)

        case Bloccs.Join.arrive({cfg.network_id, cfg.local_id}, port, msg.data, lineage) do
          :partial ->
            msg

          {:complete, payloads, parents} ->
            join_emit(msg, payloads, parents, cfg, port)

          {:error, reason} ->
            Message.failed(msg, {:join_error, reason})
        end
    end
  end

  defp join_emit(msg, payloads, parents, %Config{manifest: manifest} = cfg, port) do
    # Fan-in: the joined output's parents are the correlated arrivals.
    ctx = Bloccs.Lineage.merge(parents)

    case run_and_dispatch(manifest, payloads, cfg, ctx) do
      :ok ->
        msg

      :dropped ->
        :telemetry.execute([:bloccs, :node, :dropped], %{}, join_meta(cfg, port))
        msg

      {:dispatch_failed, failures} ->
        :telemetry.execute(
          [:bloccs, :node, :dispatch_error],
          %{count: length(failures)},
          Map.put(join_meta(cfg, port), :failures, failures)
        )

        Message.failed(msg, {:dispatch_failed, failures})

      {:error, reason} ->
        Message.failed(msg, reason)
    end
  end

  # Run a node's contract over `data` — a single payload, a list (batch), or a
  # correlated `%{port => payload}` map (join) — and dispatch the emits under the
  # lineage `lineage_ctx` (a fan-in merge for batch/join).
  defp run_and_dispatch(manifest, data, cfg, lineage_ctx) do
    ctx = Context.new(effects: Effects.bind(manifest), received_at: DateTime.utc_now())

    case run_node(manifest, data, ctx) do
      {:emits, []} ->
        :dropped

      {:emits, emits} ->
        case dispatch_all(emits, cfg, lineage_ctx) do
          [] -> :ok
          failures -> {:dispatch_failed, failures}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_meta(%Config{} = cfg), do: node_meta(cfg, cfg.in_port)
  defp join_meta(%Config{} = cfg, port), do: node_meta(cfg, port)

  defp node_meta(%Config{} = cfg, in_port) do
    %{
      network: cfg.network_id,
      node: cfg.local_id,
      in_port: in_port,
      attempt: 0,
      observability: cfg.manifest.observability
    }
  end

  defp do_process(%Message{} = msg, %Config{manifest: manifest, in_port: in_port} = cfg) do
    dedup = dedup_target(cfg, msg.data)

    case claim(dedup, msg) do
      :duplicate ->
        # Key already reserved (in-flight) or completed: ack and skip.
        emit(:skipped, %{}, cfg, msg)
        msg

      :proceed ->
        case Pipeline.validate_inbound(manifest, in_port, msg.data) do
          :ok -> run(msg, cfg, dedup)
          {:error, reason} -> fail_or_retry(msg, reason, cfg, dedup)
        end
    end
  end

  defp run(%Message{data: data} = msg, %Config{manifest: manifest} = cfg, dedup) do
    caps = Effects.bind(manifest)
    ctx = Context.new(effects: caps, received_at: DateTime.utc_now())

    case execute(manifest, data, ctx, manifest.contract.timeout_ms) do
      {:emits, emits} -> dispatch_emits(emits, msg, cfg, dedup)
      {:error, reason} -> fail_or_retry(msg, reason, cfg, dedup)
    end
  end

  # The side effect has already run; dispatching emits is delivery, not
  # re-execution. So the work is marked done up front, and a delivery failure
  # must NOT go through retry (that would re-run the effect) — instead the
  # undelivered emits fail the message so Broadway surfaces them rather than
  # silently acking as success.

  # Filter / drop: the shell returned `:drop` (or an empty list). The message is
  # consumed and acked, nothing is dispatched. A `:dropped` event records it so
  # it is visible without being mistaken for an idempotent `:skipped`.
  defp dispatch_emits([], msg, cfg, dedup) do
    mark_done(dedup)
    emit(:dropped, %{}, cfg, msg)
    msg
  end

  defp dispatch_emits(emits, msg, cfg, dedup) do
    mark_done(dedup)
    # Every emit here is caused by this one input message — its children.
    ctx = Bloccs.Lineage.child(Bloccs.Lineage.of(msg.metadata))

    case dispatch_all(emits, cfg, ctx) do
      [] ->
        msg

      failures ->
        emit(:dispatch_error, %{count: length(failures)}, cfg, msg, %{failures: failures})
        Message.failed(msg, {:dispatch_failed, failures})
    end
  end

  # Dispatch each `{port, payload}` under lineage `ctx` and collect any per-edge
  # delivery failures. Each `{port, payload}` is a distinct emitted message (its
  # own msg_id), so a split fans one input out to several tracked children.
  defp dispatch_all(emits, %Config{} = cfg, ctx) do
    Enum.flat_map(emits, fn {port, payload} ->
      case Router.dispatch(cfg.network_id, cfg.local_id, port, payload, ctx) do
        :ok -> []
        {:error, fs} -> fs
      end
    end)
  end

  # On failure, consult the node's retry policy. If the reason is retriable and
  # attempts remain, schedule a backed-off re-enqueue into this node's own
  # producer (carrying an incremented attempt count) and ack the current
  # delivery — a fresh delivery now owns the work. Otherwise fail the message.
  defp fail_or_retry(%Message{} = msg, reason, %Config{} = cfg, dedup) do
    policy = cfg.manifest.contract.retry
    attempt = attempt(msg)

    if Retry.retriable?(reason, policy, attempt) do
      delay = Retry.backoff_ms(policy, attempt)
      producer = Router.producer_name(cfg.network_id, cfg.local_id, cfg.in_port)
      # Preserve the message's lineage across the retry (it is the same message),
      # bumping only the attempt count.
      retry_meta = Map.put(msg.metadata, :bloccs_attempt, attempt + 1)
      Producer.push_after(producer, msg.data, retry_meta, delay)
      emit(:retry, %{delay_ms: delay, next_attempt: attempt + 1}, cfg, msg, %{reason: reason})
      # Keep the reservation — the scheduled retry will complete or release it.
      msg
    else
      # Terminal failure: release the reservation so the key can be reprocessed.
      release(dedup)
      Message.failed(msg, reason)
    end
  end

  defp attempt(%Message{metadata: meta}) when is_map(meta), do: Map.get(meta, :bloccs_attempt, 0)
  defp attempt(_), do: 0

  # ---------------- telemetry ----------------
  # Events (all under [:bloccs, :node, _]): :start / :stop / :exception emitted by
  # :telemetry.span around execution; :retry when a backed-off retry is scheduled;
  # :skipped when an idempotent duplicate is dropped. See Bloccs.Telemetry.

  defp base_meta(%Config{} = cfg, %Message{} = msg) do
    %{
      network: cfg.network_id,
      node: cfg.local_id,
      in_port: cfg.in_port,
      attempt: attempt(msg),
      observability: cfg.manifest.observability,
      # The input message's id, so node-level events (drop/skip/retry/fail) can be
      # correlated to a message even when nothing is emitted downstream.
      msg_id: msg_id(msg)
    }
  end

  defp msg_id(%Message{metadata: meta}) do
    case Bloccs.Lineage.of(meta) do
      %{msg_id: id} -> id
      _ -> nil
    end
  end

  defp outcome_meta(%Message{status: {:failed, reason}}), do: %{outcome: :failed, reason: reason}
  defp outcome_meta(_msg), do: %{outcome: :ok}

  defp emit(event, measurements, %Config{} = cfg, %Message{} = msg, extra \\ %{}) do
    meta = cfg |> base_meta(msg) |> Map.merge(extra)
    :telemetry.execute([:bloccs, :node, event], measurements, meta)
  end

  # Resolve the `{scope, key}` to dedup on, or nil when the node declares no
  # idempotency key (or the key field is absent from the payload).
  defp dedup_target(%Config{manifest: m, network_id: n, local_id: l}, data) do
    case idempotency_key(m.contract.idempotency, data) do
      {:ok, value} -> {{n, l}, value}
      :none -> nil
    end
  end

  defp idempotency_key(%{key: field}, data) when is_map(data), do: fetch_field(data, field)
  defp idempotency_key(_idem, _data), do: :none

  # Payloads may carry string or atom keys; try the declared field both ways.
  defp fetch_field(data, field) do
    cond do
      Map.has_key?(data, field) -> {:ok, Map.fetch!(data, field)}
      (atom = existing_atom(field)) && Map.has_key?(data, atom) -> {:ok, Map.fetch!(data, atom)}
      true -> :none
    end
  end

  defp existing_atom(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  # Atomically claim the key for this delivery. Retries (attempt > 0) already
  # own the key from the first attempt, so they bypass reservation.
  defp claim(nil, _msg), do: :proceed

  defp claim({scope, key}, msg) do
    cond do
      attempt(msg) > 0 -> :proceed
      Idempotency.reserve(scope, key) -> :proceed
      true -> :duplicate
    end
  end

  defp mark_done(nil), do: :ok
  defp mark_done({scope, key}), do: Idempotency.mark(scope, key)

  defp release(nil), do: :ok
  defp release({scope, key}), do: Idempotency.release(scope, key)

  # No declared timeout: run inline, no Task overhead.
  defp execute(manifest, data, ctx, nil), do: run_node(manifest, data, ctx)

  # Declared timeout: run pure+shell in a linked Task and bound it. The Task
  # computes the *outcome* only — router dispatch happens in the caller — so a
  # timed-out (brutally killed) Task can never emit a half-finished message.
  # `:timeout` is a transient reason (M19 retry treats it as retriable).
  defp execute(manifest, data, ctx, timeout_ms) when is_integer(timeout_ms) do
    task = Task.async(fn -> run_node(manifest, data, ctx) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:error, {:node_crash, reason}}
      nil -> {:error, :timeout}
    end
  end

  # Runs the node contract and normalizes every result/failure into either
  # `{:emits, [{port, payload}, ...]}` (possibly empty — a drop) or
  # `{:error, reason}`. Rescues/catches so a raising node never crashes the Task
  # or the processor.
  defp run_node(manifest, data, ctx) do
    pure = manifest.contract.pure_core
    shell = manifest.contract.effect_shell

    case apply(pure.module, pure.function, [data, ctx]) do
      {:ok, intermediate} ->
        normalize_emits(apply(shell.module, shell.function, [intermediate, ctx]))

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    :throw, value -> {:error, {:throw, value}}
    :exit, reason -> {:error, {:node_crash, reason}}
  end

  # Normalize the effect shell's return into `{:emits, list}` | `{:error, reason}`.
  # A single emit becomes a one-element list; `:drop` becomes the empty list; a
  # list is validated to be `{port, payload}` pairs. Anything else is a contract
  # violation surfaced as a (terminal) error rather than a crash.
  defp normalize_emits({:emit, port, payload}) when is_atom(port), do: {:emits, [{port, payload}]}
  defp normalize_emits(:drop), do: {:emits, []}
  defp normalize_emits({:error, reason}), do: {:error, reason}

  defp normalize_emits({:emit, emits}) when is_list(emits) do
    if Enum.all?(emits, &match?({port, _payload} when is_atom(port), &1)) do
      {:emits, emits}
    else
      {:error, {:bad_emit, emits}}
    end
  end

  defp normalize_emits(other), do: {:error, {:bad_return, other}}
end
