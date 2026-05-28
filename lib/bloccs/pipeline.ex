defmodule Bloccs.Pipeline do
  @moduledoc """
  Runtime helpers called from compiler-emitted Broadway pipelines.

  Centralizes the policy decisions the compiler doesn't need to know about
  (whether to schema-validate, what to do on mismatch) so they can change
  without re-running `mix bloccs.compile`.
  """

  alias Bloccs.{Schema, Manifest.Node, Manifest.Port}

  @typedoc "Reasons returned by validate_inbound/3 when validation fails."
  @type validation_error ::
          {:schema_mismatch, String.t(), [String.t()]}
          | {:unknown_port, atom()}
          | {:payload_not_map, term()}

  @doc """
  Validate a payload entering `port` against the schema declared on that
  port in the node's manifest.

  - Returns `:ok` if validation is disabled (`config :bloccs, :validate_inbound, false`),
    if the port has no schema, or if the schema isn't registered.
  - Returns `{:error, reason}` if the payload doesn't match.

  v0.1 only validates inbound. Outbound payloads are validated implicitly
  when they reach the next node's inbound check.
  """
  @spec validate_inbound(Node.t(), atom(), term()) ::
          :ok | {:error, validation_error()}
  def validate_inbound(%Node{} = manifest, port, payload) do
    if enabled?() do
      do_validate(manifest, port, payload)
    else
      :ok
    end
  end

  @doc "Returns true when runtime inbound validation is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:bloccs, :validate_inbound, true)
  end

  defp do_validate(%Node{ports_in: ports}, port, payload) do
    with {:ok, %Port{schema: schema}} <- fetch_port(ports, port),
         :ok <- ensure_map(payload),
         :ok <- check_against_schema(schema, payload) do
      :ok
    end
  end

  defp fetch_port(ports, port) do
    case Map.fetch(ports, port) do
      {:ok, %Port{} = p} -> {:ok, p}
      :error -> {:error, {:unknown_port, port}}
    end
  end

  defp ensure_map(payload) when is_map(payload), do: :ok
  defp ensure_map(other), do: {:error, {:payload_not_map, other}}

  defp check_against_schema(schema, payload) do
    case Schema.lookup(schema) do
      :error ->
        # Schema referenced by the manifest but not yet registered. v0.1
        # default is fail-soft: pipeline keeps moving. Users opting into
        # strict validation can `config :bloccs, :require_schemas, true`
        # — see require_schemas? below.
        if require_schemas?() do
          {:error, {:schema_mismatch, schema, ["schema not registered"]}}
        else
          :ok
        end

      {:ok, _} ->
        case Schema.validate(schema, payload) do
          :ok -> :ok
          {:error, reasons} -> {:error, {:schema_mismatch, schema, reasons}}
        end
    end
  end

  defp require_schemas? do
    Application.get_env(:bloccs, :require_schemas, false)
  end
end
