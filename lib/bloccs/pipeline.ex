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
    if the port has no schema, or if the schema is neither declared in a
    manifest (`schemas`) nor registered.
  - Returns `{:error, reason}` if the payload doesn't match.

  v0.1 only validates inbound. Outbound payloads are validated implicitly
  when they reach the next node's inbound check.
  """
  @spec validate_inbound(Node.t(), atom(), term(), Bloccs.Manifest.Schemas.t()) ::
          :ok | {:error, validation_error()}
  def validate_inbound(%Node{} = manifest, port, payload, schemas \\ %{}) do
    if enabled?() do
      do_validate(manifest, port, payload, schemas)
    else
      :ok
    end
  end

  @doc "Returns true when runtime inbound validation is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:bloccs, :validate_inbound, true)
  end

  defp do_validate(%Node{ports_in: ports}, port, payload, schemas) do
    with {:ok, %Port{schema: schema}} <- fetch_port(ports, port),
         :ok <- ensure_map(payload),
         :ok <- check_against_schema(schema, payload, schemas) do
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

  # A schema declared in a manifest (`schemas`) is used before the registry, so
  # a network checks against the shapes its own files declare.
  defp check_against_schema(schema, payload, schemas) do
    resolver = fn id ->
      case Map.fetch(schemas, id) do
        {:ok, fields} -> {:ok, fields}
        :error -> Schema.registry_fields(id)
      end
    end

    case resolver.(schema) do
      :error ->
        # Named by the manifest but neither declared nor registered. The
        # default is fail-soft: the pipeline keeps moving. Opt into strict
        # validation with `config :bloccs, :require_schemas, true`.
        if require_schemas?() do
          {:error, {:schema_mismatch, schema, ["schema not registered"]}}
        else
          :ok
        end

      {:ok, fields} ->
        case Schema.validate_fields(fields, payload, resolver) do
          :ok -> :ok
          {:error, reasons} -> {:error, {:schema_mismatch, schema, reasons}}
        end
    end
  end

  defp require_schemas? do
    Application.get_env(:bloccs, :require_schemas, false)
  end
end
