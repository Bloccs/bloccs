defmodule Bloccs.Runtime do
  @moduledoc """
  The execution core invoked from every compiler-emitted Broadway pipeline.

  Generated `handle_message/3` is a thin shim that builds a `Config` from the
  node's manifest plus its routing identity and calls `process/2`. Keeping the
  logic here — rather than templated into the codegen string — means inbound
  schema validation (and, in v0.2, timeout / retry / idempotency / telemetry)
  are unit-testable as ordinary library code instead of brittle generated text.

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

    failures =
      Enum.flat_map(emits, fn {port, payload} ->
        case Router.dispatch(cfg.network_id, cfg.local_id, port, payload) do
          :ok -> []
          {:error, fs} -> fs
        end
      end)

    case failures do
      [] ->
        msg

      _ ->
        emit(:dispatch_error, %{count: length(failures)}, cfg, msg, %{failures: failures})
        Message.failed(msg, {:dispatch_failed, failures})
    end
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
      Producer.push_after(producer, msg.data, %{bloccs_attempt: attempt + 1}, delay)
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
      observability: cfg.manifest.observability
    }
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
