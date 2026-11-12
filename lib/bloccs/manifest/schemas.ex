defmodule Bloccs.Manifest.Schemas do
  @moduledoc """
  Schemas declared in a manifest (`[schemas."Name@N"]`).

  A node or network manifest can declare the shape of the schemas its ports
  name, so the shape lives in the reviewed file and not only in application boot
  code:

      [schemas."Order@1"]
      id    = "string"
      total = "integer"
      tags  = ["string"]
      buyer = "Customer@1"

  A field type is one of `"string"`, `"integer"`, `"float"`, `"boolean"`,
  `"atom"`, `"map"`, a one-element array for a list of that type, or another
  schema id (`"Name@N"`).

  Declared schemas are scoped to the network that uses them. They are not put in
  the global `Bloccs.Schema` registry, so two networks can declare the same name
  with different fields. Within one network every declaration of a name must
  have the same fields (`conflicts/1`).
  """

  alias Bloccs.Manifest.{Network, NetworkNode, Node, Port}
  alias Bloccs.Schema

  @type t :: %{String.t() => [Schema.field()]}

  @scalars ~w(string integer float boolean atom map)
  @id ~r/^[A-Z][A-Za-z0-9_]*@[1-9]\d*$/

  @doc """
  Cast a decoded `[schemas]` table. Returns the schemas, or a message per
  problem found.
  """
  @spec cast(term()) :: {:ok, t()} | {:error, [String.t()]}
  def cast(raw) when is_map(raw) do
    {schemas, errors} =
      Enum.reduce(raw, {%{}, []}, fn {id, fields}, {acc, errs} ->
        case cast_schema(id, fields) do
          {:ok, cast} -> {Map.put(acc, id, cast), errs}
          {:error, e} -> {acc, e ++ errs}
        end
      end)

    if errors == [], do: {:ok, schemas}, else: {:error, Enum.sort(errors)}
  end

  def cast(_), do: {:error, ["expected a table of \"Name@N\" tables"]}

  defp cast_schema(id, fields) when is_map(fields) do
    if Regex.match?(@id, id) do
      {cast, errors} =
        Enum.reduce(fields, {[], []}, fn {name, type}, {acc, errs} ->
          case cast_type(type) do
            {:ok, t} -> {[{String.to_atom(name), t} | acc], errs}
            :error -> {acc, ["#{id}.#{name}: unknown type #{inspect(type)}" | errs]}
          end
        end)

      if errors == [], do: {:ok, Enum.sort(cast)}, else: {:error, errors}
    else
      {:error, ["schema id #{inspect(id)} must match Name@N"]}
    end
  end

  defp cast_schema(id, _), do: {:error, ["#{id}: expected a table of field = type"]}

  defp cast_type(type) when type in @scalars, do: {:ok, String.to_atom(type)}

  defp cast_type([inner]) do
    with {:ok, t} <- cast_type(inner), do: {:ok, {:list, t}}
  end

  defp cast_type(type) when is_binary(type) do
    if Regex.match?(@id, type), do: {:ok, type}, else: :error
  end

  defp cast_type(_), do: :error

  @doc """
  Every declaration in a network, as `{file, id, fields}`: the network's own
  table, the tables of any subgraph it uses, and the table of each node manifest.
  """
  @spec declarations(Network.t()) :: [{Path.t() | nil, String.t(), [Schema.field()]}]
  def declarations(%Network{} = network) do
    own = for {id, fields} <- network.schemas, do: {network.path, id, fields}

    subgraphs =
      for {path, schemas} <- network.subgraph_schemas,
          {id, fields} <- schemas,
          do: {path, id, fields}

    nodes =
      for {_, %NetworkNode{manifest: %Node{path: path, schemas: schemas}}} <- network.nodes,
          {id, fields} <- schemas,
          do: {path, id, fields}

    Enum.uniq(own ++ subgraphs ++ nodes)
  end

  @doc """
  The schemas a network declares, by id. When a name is declared more than once
  the declarations must agree (see `conflicts/1`), so which one is kept does not
  matter for a valid network.
  """
  @spec merged(Network.t()) :: t()
  def merged(%Network{} = network) do
    network
    |> declarations()
    |> Enum.reverse()
    |> Map.new(fn {_file, id, fields} -> {id, fields} end)
  end

  @doc """
  Names that are declared with different fields in different files, as
  `{id, [file]}`.
  """
  @spec conflicts(Network.t()) :: [{String.t(), [Path.t() | nil]}]
  def conflicts(%Network{} = network) do
    network
    |> declarations()
    |> Enum.group_by(fn {_file, id, _fields} -> id end)
    |> Enum.filter(fn {_id, decls} ->
      decls |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() > 1
    end)
    |> Enum.map(fn {id, decls} -> {id, decls |> Enum.map(&elem(&1, 0)) |> Enum.sort()} end)
    |> Enum.sort()
  end

  @doc """
  Schema ids that a declared schema names as a field type but that no manifest
  in the set declares, as `{id, field, missing_id}`.
  """
  @spec dangling_refs(t()) :: [{String.t(), atom(), String.t()}]
  def dangling_refs(schemas) when is_map(schemas) do
    for {id, fields} <- Enum.sort(schemas),
        {name, type} <- fields,
        ref = ref_of(type),
        ref != nil,
        not Map.has_key?(schemas, ref),
        do: {id, name, ref}
  end

  @doc """
  The part of `schemas` one node needs at runtime: the schemas its in-ports
  name, and every schema those name in turn.
  """
  @spec for_node(t(), Node.t()) :: t()
  def for_node(schemas, %Node{ports_in: ports_in}) do
    roots = for {_, %Port{schema: id}} <- ports_in, do: id
    Map.take(schemas, closure(roots, schemas, MapSet.new()))
  end

  defp closure([], _schemas, seen), do: MapSet.to_list(seen)

  defp closure([id | rest], schemas, seen) do
    case {MapSet.member?(seen, id), Map.fetch(schemas, id)} do
      {false, {:ok, fields}} ->
        refs = for {_, type} <- fields, ref = ref_of(type), ref != nil, do: ref
        closure(refs ++ rest, schemas, MapSet.put(seen, id))

      _ ->
        closure(rest, schemas, seen)
    end
  end

  defp ref_of({:list, inner}), do: ref_of(inner)
  defp ref_of(ref) when is_binary(ref), do: ref
  defp ref_of(_), do: nil
end
