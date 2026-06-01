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

  alias Bloccs.{Context, Effects, Manifest.Node, Pipeline, Router}
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
      {:error, reason} -> Message.failed(msg, reason)
    end
  end

  defp run(%Message{data: data} = msg, %Config{manifest: manifest} = cfg) do
    caps = Effects.bind(manifest)
    ctx = Context.new(effects: caps, received_at: DateTime.utc_now())

    pure = manifest.contract.pure_core
    shell = manifest.contract.effect_shell

    try do
      with {:ok, intermediate} <- apply(pure.module, pure.function, [data, ctx]),
           {:emit, port, payload} <- apply(shell.module, shell.function, [intermediate, ctx]) do
        Router.dispatch(cfg.network_id, cfg.local_id, port, payload)
        msg
      else
        {:error, reason} -> Message.failed(msg, reason)
      end
    rescue
      e -> Message.failed(msg, e)
    end
  end
end
