defmodule Bloccs.Validator do
  @moduledoc """
  Contract validator for parsed node + network manifests.

  Accumulates every problem it finds rather than short-circuiting. Returns
  `:ok` or `{:error, [%Bloccs.Validator.Issue{}]}`.

  Checks for a node:

  - effects use only known capabilities (http, db, time, random)
  - port schemas resolve in `Bloccs.Schema` (deferred until M5 with `:require_schemas`)
  - `pure_core` / `effect_shell` MFAs are well-formed
  - retry/timeout/idempotency keys are well-typed

  Checks for a network:

  - every edge `from`/`to` references a known node port
  - edge schemas match across the wire
  - the graph is a DAG (no cycles; v0.1 = DAG-only)
  - `[expose]` references real node ports
  - supervision strategy ∈ valid set
  """

  alias Bloccs.Manifest.{Node, Network, Edge, NetworkNode, Effects, Contract, Port}

  @known_effects [:http, :db, :time, :random]

  defmodule Issue do
    @moduledoc "A structured validation diagnostic."

    @type level :: :error | :warning

    @type t :: %__MODULE__{
            level: level(),
            file: Path.t() | nil,
            scope: String.t(),
            message: String.t()
          }

    defstruct level: :error, file: nil, scope: nil, message: nil
  end

  @doc """
  Validate a parsed node manifest. By default the function existence is NOT
  checked (that's the macro's job at compile time). Pass `:require_schemas`
  if you want every port schema to be required-registered.
  """
  @spec validate_node(Node.t(), keyword()) :: :ok | {:error, [Issue.t()]}
  def validate_node(%Node{} = node, opts \\ []) do
    issues =
      List.flatten([
        check_effects(node),
        check_contract(node),
        check_ports(node, opts)
      ])

    ok_or_errors(issues)
  end

  @doc """
  Validate a parsed network manifest. Validates each contained node first;
  if any node fails, network-level checks still run so the user sees the
  whole picture.
  """
  @spec validate_network(Network.t(), keyword()) :: :ok | {:error, [Issue.t()]}
  def validate_network(%Network{} = network, opts \\ []) do
    node_issues =
      Enum.flat_map(network.nodes, fn {local_id, %NetworkNode{manifest: manifest}} ->
        case validate_node(manifest, opts) do
          :ok -> []
          {:error, issues} -> Enum.map(issues, &prepend_scope(&1, "nodes.#{local_id}"))
        end
      end)

    issues =
      List.flatten([
        node_issues,
        check_edges(network),
        check_acyclic(network),
        check_expose(network),
        check_supervision(network)
      ])

    ok_or_errors(issues)
  end

  defp ok_or_errors([]), do: :ok
  defp ok_or_errors(issues), do: {:error, Enum.reverse(issues)}

  defp prepend_scope(%Issue{scope: nil} = i, prefix), do: %{i | scope: prefix}
  defp prepend_scope(%Issue{scope: s} = i, prefix), do: %{i | scope: "#{prefix} → #{s}"}

  # ---------- warnings (parsed-but-not-wired manifest fields) ----------

  @doc """
  Return advisory warnings about manifest fields that are accepted by the
  parser but not yet honoured at runtime.

  Returns a flat list of `%Issue{level: :warning}`. Callers decide how to
  surface them — `Bloccs.Node` `__using__/1` emits `IO.warn`; the CLI tasks
  print a yellow block.

  As of v0.2 the node-level runtime fields (`[contract].retry` / `timeout_ms` /
  `idempotency`, `[ports.in].<port>.buffer`, `[observability]`) are all wired,
  so node manifests produce no unwired warnings. The only remaining unwired
  field is network-level `[expose]` — subgraph composition (network-as-node)
  is still deferred.
  """
  @spec warnings(Node.t() | Network.t()) :: [Issue.t()]
  def warnings(%Node{} = node), do: node_warnings(node)

  def warnings(%Network{} = network) do
    node_warnings =
      Enum.flat_map(network.nodes, fn {local_id, %NetworkNode{manifest: m}} ->
        Enum.map(node_warnings(m), &prepend_scope(&1, "nodes.#{local_id}"))
      end)

    node_warnings ++ network_warnings(network)
  end

  # All node-level runtime fields are wired as of v0.2; nothing to warn about.
  defp node_warnings(%Node{}), do: []

  defp network_warnings(%Network{expose: e, path: path}) do
    count = map_size(e.in) + map_size(e.out)

    if count > 0 do
      [
        %Issue{
          level: :warning,
          file: path,
          scope: "[expose]",
          message:
            "declares #{map_size(e.in)} in / #{map_size(e.out)} out exposed ports, " <>
              "but subgraph composition (network-as-node) is not yet implemented. " <>
              "These values are stored without being consumed. " <>
              "See docs/v0.1-audit.md."
        }
      ]
    else
      []
    end
  end

  # ---------- node checks ----------

  defp check_effects(%Node{effects: %Effects{} = e, path: path}) do
    declared = Effects.declared(e)
    unknown = declared -- @known_effects

    Enum.map(unknown, fn axis ->
      %Issue{
        file: path,
        scope: "[effects]",
        message:
          "unknown effect capability #{inspect(axis)} " <>
            "(known: #{inspect(@known_effects)})"
      }
    end)
  end

  defp check_contract(%Node{contract: %Contract{} = c, path: path}) do
    [
      check_mfa_shape(c.pure_core, "pure_core", path),
      check_mfa_shape(c.effect_shell, "effect_shell", path),
      check_retry(c.retry, path),
      check_timeout(c.timeout_ms, path),
      check_idempotency(c.idempotency, path)
    ]
  end

  defp check_mfa_shape(%{module: m, function: f, arity: a}, _label, _path)
       when is_atom(m) and is_atom(f) and is_integer(a),
       do: []

  defp check_mfa_shape(other, label, path),
    do: [
      %Issue{
        file: path,
        scope: "[contract].#{label}",
        message: "expected Module.fun/N, got #{inspect(other)}"
      }
    ]

  defp check_retry(nil, _path), do: []

  defp check_retry(%{strategy: s, max: m, on: on}, _path)
       when is_binary(s) and is_integer(m) and m >= 0 and is_list(on),
       do: []

  defp check_retry(other, path),
    do: [
      %Issue{
        file: path,
        scope: "[contract].retry",
        message: "expected %{strategy, max, on}, got #{inspect(other)}"
      }
    ]

  defp check_timeout(nil, _), do: []
  defp check_timeout(n, _) when is_integer(n) and n > 0, do: []

  defp check_timeout(n, path),
    do: [
      %Issue{
        file: path,
        scope: "[contract].timeout_ms",
        message: "expected positive integer, got #{inspect(n)}"
      }
    ]

  defp check_idempotency(nil, _), do: []
  defp check_idempotency(%{key: k}, _) when is_binary(k), do: []

  defp check_idempotency(other, path),
    do: [
      %Issue{
        file: path,
        scope: "[contract].idempotency",
        message: "expected %{key: \"...\"}, got #{inspect(other)}"
      }
    ]

  defp check_ports(%Node{ports_in: i, ports_out: o, path: path}, opts) do
    require_schemas? = Keyword.get(opts, :require_schemas, false)

    in_issues =
      Enum.flat_map(i, fn {_, %Port{} = p} ->
        check_one_port(p, "[ports.in]", path, require_schemas?)
      end)

    out_issues =
      Enum.flat_map(o, fn {_, %Port{} = p} ->
        check_one_port(p, "[ports.out]", path, require_schemas?)
      end)

    in_issues ++ out_issues
  end

  defp check_one_port(%Port{schema: schema, name: name}, section, path, require?) do
    cond do
      not is_binary(schema) ->
        [%Issue{file: path, scope: "#{section}.#{name}", message: "schema must be a string"}]

      not Regex.match?(~r/^[A-Z][A-Za-z0-9_]*@\d+$/, schema) ->
        [
          %Issue{
            file: path,
            scope: "#{section}.#{name}",
            message: "schema #{inspect(schema)} must match Name@N"
          }
        ]

      require? and Bloccs.Schema.lookup(schema) == :error ->
        [
          %Issue{
            file: path,
            scope: "#{section}.#{name}",
            message: "schema #{schema} is not registered"
          }
        ]

      true ->
        []
    end
  end

  # ---------- network checks ----------

  defp check_edges(%Network{nodes: nodes, edges: edges, path: path}) do
    Enum.flat_map(edges, fn %Edge{from: from, to: tos} = edge ->
      check_from = check_endpoint(:out, from, nodes, path, edge)
      check_tos = Enum.flat_map(tos, &check_endpoint(:in, &1, nodes, path, edge))
      schema_match = check_edge_schemas(edge, nodes, path)
      check_from ++ check_tos ++ schema_match
    end)
  end

  defp check_endpoint(direction, {local_id, port}, nodes, path, edge) do
    case Map.fetch(nodes, local_id) do
      :error ->
        [
          %Issue{
            file: path,
            scope: "[[edges]]",
            message: "edge #{format_edge(edge)} references unknown node #{inspect(local_id)}"
          }
        ]

      {:ok, %NetworkNode{manifest: m}} ->
        ports =
          case direction do
            :out -> m.ports_out
            :in -> m.ports_in
          end

        if Map.has_key?(ports, port) do
          []
        else
          [
            %Issue{
              file: path,
              scope: "[[edges]]",
              message:
                "edge #{format_edge(edge)} references unknown port " <>
                  "#{inspect(local_id)}.#{port} (#{direction})"
            }
          ]
        end
    end
  end

  defp check_edge_schemas(%Edge{from: {fn_id, fp}, to: tos} = edge, nodes, path) do
    with {:ok, %NetworkNode{manifest: from_m}} <- Map.fetch(nodes, fn_id),
         {:ok, %Port{schema: from_schema}} <- Map.fetch(from_m.ports_out, fp) do
      Enum.flat_map(tos, fn {tn_id, tp} ->
        with {:ok, %NetworkNode{manifest: to_m}} <- Map.fetch(nodes, tn_id),
             {:ok, %Port{schema: to_schema}} <- Map.fetch(to_m.ports_in, tp) do
          if from_schema == to_schema do
            []
          else
            [
              %Issue{
                file: path,
                scope: "[[edges]]",
                message:
                  "edge #{format_edge(edge)} schema mismatch: " <>
                    "#{fn_id}.#{fp}=#{from_schema} but #{tn_id}.#{tp}=#{to_schema}"
              }
            ]
          end
        else
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp format_edge(%Edge{from: {fn_id, fp}, to: tos}) do
    "#{fn_id}.#{fp} → " <>
      Enum.map_join(tos, ", ", fn {tn, tp} -> "#{tn}.#{tp}" end)
  end

  defp check_acyclic(%Network{nodes: nodes, edges: edges, path: path}) do
    adjacency =
      Enum.reduce(edges, %{}, fn %Edge{from: {f, _}, to: tos}, acc ->
        targets = Enum.map(tos, fn {t, _} -> t end)
        Map.update(acc, f, targets, &(&1 ++ targets))
      end)

    case detect_cycle(Map.keys(nodes), adjacency) do
      {:cycle, path_nodes} ->
        [
          %Issue{
            file: path,
            scope: "[[edges]]",
            message:
              "network contains a cycle (v0.1 = DAG-only): " <>
                Enum.join(path_nodes, " → ")
          }
        ]

      :ok ->
        []
    end
  end

  defp detect_cycle(nodes, adjacency) do
    Enum.reduce_while(nodes, :ok, fn n, _ ->
      case dfs(n, adjacency, MapSet.new(), []) do
        :ok -> {:cont, :ok}
        {:cycle, p} -> {:halt, {:cycle, p}}
      end
    end)
  end

  defp dfs(node, adjacency, visiting, path) do
    cond do
      node in path ->
        cycle = path |> Enum.reverse() |> Enum.drop_while(&(&1 != node))
        {:cycle, cycle ++ [node]}

      MapSet.member?(visiting, node) ->
        :ok

      true ->
        children = Map.get(adjacency, node, [])
        new_path = [node | path]

        Enum.reduce_while(children, :ok, fn child, _ ->
          case dfs(child, adjacency, visiting, new_path) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
        end)
    end
  end

  defp check_expose(%Network{expose: e, nodes: nodes, path: path}) do
    in_issues =
      Enum.flat_map(e.in, fn {expose_name, {nid, port}} ->
        if endpoint_exists?(nodes, nid, port, :in) do
          []
        else
          [
            %Issue{
              file: path,
              scope: "[expose].in.#{expose_name}",
              message: "references unknown port #{nid}.#{port}"
            }
          ]
        end
      end)

    out_issues =
      Enum.flat_map(e.out, fn {expose_name, {nid, port}} ->
        if endpoint_exists?(nodes, nid, port, :out) do
          []
        else
          [
            %Issue{
              file: path,
              scope: "[expose].out.#{expose_name}",
              message: "references unknown port #{nid}.#{port}"
            }
          ]
        end
      end)

    in_issues ++ out_issues
  end

  defp endpoint_exists?(nodes, local_id, port, direction) do
    case Map.fetch(nodes, local_id) do
      {:ok, %NetworkNode{manifest: m}} ->
        ports =
          case direction do
            :in -> m.ports_in
            :out -> m.ports_out
          end

        Map.has_key?(ports, port)

      _ ->
        false
    end
  end

  defp check_supervision(%Network{supervision: s, path: path}) do
    if s.strategy in Bloccs.Manifest.Supervision.valid_strategies() do
      []
    else
      [
        %Issue{
          file: path,
          scope: "[supervision].strategy",
          message: "unknown strategy #{inspect(s.strategy)}"
        }
      ]
    end
  end
end
