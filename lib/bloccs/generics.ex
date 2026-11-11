defmodule Bloccs.Generics do
  @moduledoc """
  SPIKE (VEN-76): bounded generic ports.

  A node may declare an in-port as a type variable with a bound:

      [ports.in]
      in  = { schema = "$T", requires = "Keyed@1" }
      [ports.out]
      out = { schema = "$T" }

  When the node is wired into a network, `$T` is bound to the schema of the
  out-port feeding it. The bound schema must have every field of the `requires`
  schema with the same type. The node's `$T` out-ports then carry the bound
  schema, so downstream edges keep the producer's full type. Everything else
  stays nominal.
  """

  alias Bloccs.Manifest.{Network, NetworkNode, Edge, Port}

  @types ~w(string integer float boolean atom map)

  @doc "Cast a `[schemas]` table: `\"Name@N\" = { field = \"type\" }`."
  def cast_schemas(raw) when is_map(raw) do
    Map.new(raw, fn {id, fields} ->
      {id,
       fields
       |> Enum.map(fn {k, t} when t in @types -> {String.to_atom(k), String.to_atom(t)} end)
       |> Enum.sort()}
    end)
  end

  @doc "Register a network's `[schemas]` in the runtime registry."
  def register_schemas(%Network{schemas: schemas}) do
    Enum.each(schemas, fn {id, fields} -> Bloccs.Schema.register(id, fields) end)
  end

  @spec resolve(Network.t()) :: {:ok, Network.t()} | {:error, [String.t()]}
  def resolve(%Network{} = network) do
    if generic?(network), do: loop(network, map_size(network.nodes) + 1), else: {:ok, network}
  end

  defp generic?(%Network{nodes: nodes}),
    do: Enum.any?(nodes, fn {_, nn} -> unbound_ports(nn) != [] end)

  defp unbound_ports(%NetworkNode{manifest: m}),
    do: for({_, %Port{schema: "$" <> _} = p} <- m.ports_in, do: p)

  # Bind one layer per pass (a generic node fed by another generic node resolves
  # on the next pass). A DAG of N nodes settles in at most N passes.
  defp loop(network, 0), do: {:error, unresolved(network)}

  defp loop(network, budget) do
    {nodes, errors, changed?} =
      Enum.reduce(network.nodes, {network.nodes, [], false}, fn {id, nn}, {nodes, errs, ch} ->
        case unbound_ports(nn) do
          [] ->
            {nodes, errs, ch}

          ports ->
            case bind(network, id, nn, ports) do
              {:ok, bound} -> {Map.put(nodes, id, bound), errs, true}
              :wait -> {nodes, errs, ch}
              {:error, e} -> {nodes, e ++ errs, ch}
            end
        end
      end)

    network = %{network | nodes: nodes}

    cond do
      errors != [] -> {:error, Enum.reverse(errors)}
      not generic?(network) -> {:ok, network}
      changed? -> loop(network, budget - 1)
      true -> {:error, unresolved(network)}
    end
  end

  defp unresolved(network) do
    for {id, nn} <- network.nodes, p <- unbound_ports(nn) do
      "generic port #{id}.#{p.name} (#{p.schema}) has no concrete schema wired into it"
    end
  end

  defp bind(network, id, %NetworkNode{manifest: m} = nn, ports) do
    Enum.reduce_while(ports, {:ok, nn}, fn %Port{name: port, schema: var, requires: req},
                                           {:ok, acc} ->
      feeders =
        for %Edge{from: {fid, fp}, to: tos} <- network.edges, {^id, ^port} <- tos do
          {fid, fp, network.nodes[fid].manifest.ports_out[fp].schema}
        end

      schemas = feeders |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

      cond do
        feeders == [] ->
          {:halt, {:error, ["generic port #{id}.#{port} (#{var}) has no edge wired into it"]}}

        Enum.any?(schemas, &String.starts_with?(&1, "$")) ->
          {:halt, :wait}

        length(schemas) > 1 ->
          {:halt,
           {:error,
            [
              "generic port #{id}.#{port} (#{var}) is fed different schemas: #{Enum.join(schemas, ", ")}"
            ]}}

        true ->
          [schema] = schemas

          case satisfies(network, schema, req) do
            :ok ->
              m2 = acc.manifest

              sub = fn ports ->
                Map.new(ports, fn {k, p} ->
                  {k, if(p.schema == var, do: %{p | schema: schema}, else: p)}
                end)
              end

              {:cont,
               {:ok,
                %{
                  acc
                  | manifest: %{m2 | ports_in: sub.(m2.ports_in), ports_out: sub.(m2.ports_out)}
                }}}

            {:error, why} ->
              {fid, fp, _} = hd(feeders)

              {:halt,
               {:error,
                ["edge #{fid}.#{fp} → #{id}.#{port}: #{schema} does not satisfy #{req} (#{why})"]}}
          end
      end
    end)
    |> case do
      {:ok, bound} -> if bound.manifest == m, do: :wait, else: {:ok, bound}
      other -> other
    end
  end

  # Fail closed: both shapes must be known, or the edge is rejected.
  defp satisfies(network, schema, req) do
    with {:ok, have} <- fields(network, schema),
         {:ok, need} <- fields(network, req) do
      problems =
        for {name, type} <- need do
          case List.keyfind(have, name, 0) do
            nil -> "missing field #{name}"
            {_, ^type} -> nil
            {_, other} -> "field #{name} is #{inspect(other)}, needs #{inspect(type)}"
          end
        end
        |> Enum.reject(&is_nil/1)

      if problems == [], do: :ok, else: {:error, Enum.join(problems, "; ")}
    else
      {:unknown, id} -> {:error, "the shape of #{id} is not declared"}
    end
  end

  defp fields(%Network{schemas: schemas}, id) do
    case Map.fetch(schemas, id) do
      {:ok, f} ->
        {:ok, f}

      :error ->
        case Bloccs.Schema.lookup(id) do
          {:ok, s} -> {:ok, s.fields}
          :error -> {:unknown, id}
        end
    end
  end
end
