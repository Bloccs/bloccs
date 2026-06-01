defmodule Bloccs.Runtime do
  @moduledoc """
  The execution core invoked from every compiler-emitted Broadway pipeline.

  Generated `handle_message/3` is a thin shim that builds a `Config` from the
  node's manifest plus its routing identity and calls `process/2`. Keeping the
  logic here — rather than templated into the codegen string — means inbound
  schema validation (and, in v0.2, timeout / retry / idempotency / telemetry)
  are unit-testable as ordinary library code instead of brittle generated text.

  The contract with a node implementation is unchanged:

      pure_core(data, ctx)  :: {:ok, intermediate} | {:error, reason}
      effect_shell(mid, ctx) :: {:emit, port, payload} | {:error, reason}
  """

  alias Bloccs.{Context, Effects, Manifest.Node, Pipeline, Producer, Retry, Router}
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
  def process(%Message{} = msg, %Config{manifest: manifest, in_port: in_port} = cfg) do
    case Pipeline.validate_inbound(manifest, in_port, msg.data) do
      :ok -> run(msg, cfg)
      {:error, reason} -> fail_or_retry(msg, reason, cfg)
    end
  end

  defp run(%Message{data: data} = msg, %Config{manifest: manifest} = cfg) do
    caps = Effects.bind(manifest)
    ctx = Context.new(effects: caps, received_at: DateTime.utc_now())

    case execute(manifest, data, ctx, manifest.contract.timeout_ms) do
      {:emit, port, payload} ->
        Router.dispatch(cfg.network_id, cfg.local_id, port, payload)
        msg

      {:error, reason} ->
        fail_or_retry(msg, reason, cfg)
    end
  end

  # On failure, consult the node's retry policy. If the reason is retriable and
  # attempts remain, schedule a backed-off re-enqueue into this node's own
  # producer (carrying an incremented attempt count) and ack the current
  # delivery — a fresh delivery now owns the work. Otherwise fail the message.
  defp fail_or_retry(%Message{} = msg, reason, %Config{} = cfg) do
    policy = cfg.manifest.contract.retry
    attempt = attempt(msg)

    if Retry.retriable?(reason, policy, attempt) do
      delay = Retry.backoff_ms(policy, attempt)
      producer = Router.producer_name(cfg.network_id, cfg.local_id, cfg.in_port)
      Producer.push_after(producer, msg.data, %{bloccs_attempt: attempt + 1}, delay)
      msg
    else
      Message.failed(msg, reason)
    end
  end

  defp attempt(%Message{metadata: meta}) when is_map(meta), do: Map.get(meta, :bloccs_attempt, 0)
  defp attempt(_), do: 0

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
  # `{:emit, port, payload}` or `{:error, reason}`. Rescues/catches so a raising
  # node never crashes the Task or the processor.
  defp run_node(manifest, data, ctx) do
    pure = manifest.contract.pure_core
    shell = manifest.contract.effect_shell

    with {:ok, intermediate} <- apply(pure.module, pure.function, [data, ctx]),
         {:emit, _port, _payload} = emit <-
           apply(shell.module, shell.function, [intermediate, ctx]) do
      emit
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    :throw, value -> {:error, {:throw, value}}
    :exit, reason -> {:error, {:node_crash, reason}}
  end
end
