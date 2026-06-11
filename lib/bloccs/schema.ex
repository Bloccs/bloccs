defmodule Bloccs.Schema do
  @moduledoc """
  Versioned schema registry (`Name@N`).

  Schemas declare the shape of payloads flowing between node ports. v0.1 ships
  a deliberately minimal API surface — this is the swap-out point for Protobuf
  or Avro at v0.5+.

  A schema is identified by `"Name@Version"` (e.g. `"Event@1"`). Fields are a
  keyword list of `{name, type}` pairs. Types: `:string`, `:integer`, `:float`,
  `:boolean`, `:atom`, `:map`, `{:list, type}`, or another schema reference
  string.

  ## Example

      Bloccs.Schema.register("Event@1",
        id: :string,
        type: :string,
        payload: :map
      )

      Bloccs.Schema.validate("Event@1", %{
        id: "evt_1",
        type: "order.created",
        payload: %{"order_id" => 1001}
      })
      #=> :ok

  The registry is backed by `:persistent_term` so lookups are fast and lock-free.
  Schemas are registered eagerly by the consuming application (or by the manifest
  parser as it walks port declarations).
  """

  @type field_type ::
          :string
          | :integer
          | :float
          | :boolean
          | :atom
          | :map
          | {:list, field_type()}
          | String.t()

  @type field :: {atom(), field_type()}
  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          fields: [field()]
        }

  defstruct [:name, :version, :fields]

  @registry_key :bloccs_schema_registry

  @doc """
  Register a schema. Idempotent — re-registering with the same fields is a no-op;
  changing the fields raises.

  Accepts the `"Name@N"` shorthand or an explicit `{name, version}` tuple.
  """
  @spec register(String.t() | {String.t(), pos_integer()}, [field()]) :: :ok
  def register(id, fields) when is_binary(id) do
    {name, version} = parse_id!(id)
    register({name, version}, fields)
  end

  def register({name, version}, fields) when is_binary(name) and is_integer(version) do
    schema = %__MODULE__{name: name, version: version, fields: fields}
    id = format_id(name, version)

    case lookup(id) do
      {:ok, ^schema} ->
        :ok

      {:ok, existing} ->
        raise ArgumentError,
              "schema #{id} already registered with different fields: " <>
                "existing=#{inspect(existing.fields)} new=#{inspect(fields)}"

      :error ->
        put(id, schema)
    end
  end

  @doc """
  Look up a schema by `"Name@N"`.
  """
  @spec lookup(String.t()) :: {:ok, t()} | :error
  def lookup(id) when is_binary(id) do
    case :persistent_term.get({@registry_key, id}, :undefined) do
      :undefined -> :error
      schema -> {:ok, schema}
    end
  end

  @doc """
  Look up a schema, raising if missing.
  """
  @spec fetch!(String.t()) :: t()
  def fetch!(id) do
    case lookup(id) do
      {:ok, schema} -> schema
      :error -> raise KeyError, "schema #{id} not registered"
    end
  end

  @doc """
  Validate that a payload matches a registered schema. Returns `:ok` or
  `{:error, [reason]}` listing every problem found.
  """
  @spec validate(String.t(), map()) :: :ok | {:error, [String.t()]}
  def validate(id, payload) when is_binary(id) and is_map(payload) do
    schema = fetch!(id)
    errors = Enum.flat_map(schema.fields, &validate_field(&1, payload))

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Parse a `"Name@N"` identifier. Raises on malformed input.
  """
  @spec parse_id!(String.t()) :: {String.t(), pos_integer()}
  def parse_id!(id) when is_binary(id) do
    case String.split(id, "@", parts: 2) do
      [name, version] when name != "" ->
        case Integer.parse(version) do
          {v, ""} when v > 0 -> {name, v}
          _ -> raise ArgumentError, "invalid schema id #{inspect(id)} (expected Name@N, N > 0)"
        end

      _ ->
        raise ArgumentError, "invalid schema id #{inspect(id)} (expected Name@N)"
    end
  end

  @doc """
  Format a `{name, version}` pair as `"Name@N"`.
  """
  @spec format_id(String.t(), pos_integer()) :: String.t()
  def format_id(name, version), do: "#{name}@#{version}"

  @doc """
  List every registered schema id.
  """
  @spec list() :: [String.t()]
  def list do
    :persistent_term.get()
    |> Enum.filter(&match?({{@registry_key, _id}, _schema}, &1))
    |> Enum.map(fn {{@registry_key, id}, _} -> id end)
    |> Enum.sort()
  end

  @doc """
  Clear the entire registry. Test-only — never call from application code.
  """
  @spec clear!() :: :ok
  def clear! do
    for {{@registry_key, id}, _} <- :persistent_term.get(),
        do: :persistent_term.erase({@registry_key, id})

    :ok
  end

  defp put(id, schema) do
    :persistent_term.put({@registry_key, id}, schema)
  end

  defp validate_field({name, type}, payload) do
    case Map.fetch(payload, name) do
      :error ->
        case Map.fetch(payload, to_string(name)) do
          {:ok, value} -> check_type(name, type, value)
          :error -> ["missing field #{name}"]
        end

      {:ok, value} ->
        check_type(name, type, value)
    end
  end

  defp check_type(_name, :string, v) when is_binary(v), do: []
  defp check_type(_name, :integer, v) when is_integer(v), do: []
  defp check_type(_name, :float, v) when is_float(v), do: []
  defp check_type(_name, :boolean, v) when is_boolean(v), do: []
  defp check_type(_name, :atom, v) when is_atom(v), do: []
  defp check_type(_name, :map, v) when is_map(v), do: []

  defp check_type(name, {:list, inner}, v) when is_list(v) do
    v
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      # The element name is only ever interpolated into error messages, so it
      # stays a binary — atoms are never GC'd, and payload-sized lists would
      # otherwise grow the atom table without bound.
      case check_type("#{name}[#{idx}]", inner, item) do
        [] -> []
        errs -> errs
      end
    end)
  end

  defp check_type(name, ref, v) when is_binary(ref) do
    case lookup(ref) do
      {:ok, _} when is_map(v) -> validate_nested(ref, v)
      {:ok, _} -> ["field #{name} must be a map matching #{ref}"]
      :error -> ["field #{name} references unknown schema #{ref}"]
    end
  end

  defp check_type(name, type, v),
    do: ["field #{name}: expected #{inspect(type)}, got #{inspect(v)}"]

  defp validate_nested(ref, payload) do
    case validate(ref, payload) do
      :ok -> []
      {:error, errs} -> Enum.map(errs, &"#{ref}.#{&1}")
    end
  end
end
