defmodule Bloccs.Parser do
  @moduledoc """
  Parses `.bloccs` TOML manifests into typed structs.

  Two entry points: `parse_node/1` and `parse_network/1`. Each returns either
  `{:ok, struct}` or `{:error, [%Bloccs.Parser.Error{}]}`. Errors are
  accumulated, not short-circuited, so one bad manifest surfaces all of its
  problems in a single pass.
  """

  alias Bloccs.Manifest.{
    Node,
    Network,
    NetworkNode,
    Edge,
    Expose,
    Supervision,
    Effects,
    Contract,
    Doc,
    Port
  }

  alias Bloccs.Parser.Error

  defmodule Error do
    @moduledoc "A structured parser error pinned to a file + section."
    @type t :: %__MODULE__{
            file: Path.t() | nil,
            section: String.t() | nil,
            message: String.t()
          }
    defstruct [:file, :section, :message]
  end

  @doc "Parse a node manifest from a file path."
  @spec parse_node(Path.t()) :: {:ok, Node.t()} | {:error, [Error.t()]}
  def parse_node(path) do
    with {:ok, text} <- read(path),
         {:ok, map} <- decode(text, path) do
      cast_node(map, path)
    end
  end

  @doc "Parse a node manifest from a binary string (no file association)."
  @spec parse_node_string(String.t(), Path.t() | nil) :: {:ok, Node.t()} | {:error, [Error.t()]}
  def parse_node_string(text, path \\ nil) do
    with {:ok, map} <- decode(text, path) do
      cast_node(map, path)
    end
  end

  @doc """
  Parse a network manifest from a file path.

  Recursively loads every node referenced by `[nodes].X.use = "..."`. Node
  paths are resolved relative to the network file's directory.
  """
  @spec parse_network(Path.t()) :: {:ok, Network.t()} | {:error, [Error.t()]}
  def parse_network(path), do: do_parse_network(path, MapSet.new())

  # `visited` is the set of (expanded) network paths in the current composition
  # chain, used to detect subgraph cycles.
  defp do_parse_network(path, visited) do
    with {:ok, text} <- read(path),
         {:ok, map} <- decode(text, path) do
      cast_network(map, path, MapSet.put(visited, Path.expand(path)))
    end
  end

  # ---------------- internal ----------------

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, [%Error{file: path, message: "cannot read file: #{reason}"}]}
    end
  end

  defp decode(text, path) do
    cond do
      not is_binary(text) ->
        {:error, [%Error{file: path, message: "manifest must be a binary"}]}

      not String.valid?(text) ->
        {:error, [%Error{file: path, message: "manifest is not valid UTF-8"}]}

      true ->
        try do
          case Toml.decode(text) do
            {:ok, map} ->
              {:ok, map}

            {:error, reason} ->
              {:error, [%Error{file: path, message: "TOML parse error: #{inspect(reason)}"}]}
          end
        rescue
          e ->
            {:error, [%Error{file: path, message: "TOML decode error: #{Exception.message(e)}"}]}
        catch
          kind, reason ->
            {:error, [%Error{file: path, message: "TOML decode #{kind}: #{inspect(reason)}"}]}
        end
    end
  end

  # ---------- node cast ----------

  defp cast_node(map, path) do
    {fields, errors} =
      reduce_field_casts(map, path, [
        {:node, "[node]", &cast_node_meta/1},
        {:doc, "[doc]", &cast_doc/1, true},
        {:ports_in, "[ports.in]", &cast_ports(&1, "[ports.in]")},
        {:ports_out, "[ports.out]", &cast_ports(&1, "[ports.out]")},
        {:effects, "[effects]", &cast_effects/1},
        {:contract, "[contract]", &cast_contract/1},
        {:observability, "[observability]", &cast_observability/1, true}
      ])

    if errors == [] do
      meta = fields[:node]

      node = %Node{
        path: path,
        id: meta.id,
        version: meta.version,
        kind: meta.kind,
        doc: fields[:doc],
        ports_in: fields[:ports_in] || %{},
        ports_out: fields[:ports_out] || %{},
        effects: fields[:effects] || %Effects{},
        contract: fields[:contract],
        observability: fields[:observability] || %{}
      }

      {:ok, node}
    else
      {:error, Enum.map(errors, &%{&1 | file: &1.file || path})}
    end
  end

  defp reduce_field_casts(map, path, defs) do
    Enum.reduce(defs, {%{}, []}, fn def, {acc_fields, acc_errors} ->
      {section_key, label, fun, optional?} =
        case def do
          {key, label, fun} -> {key, label, fun, false}
          {key, label, fun, optional?} -> {key, label, fun, optional?}
        end

      raw = fetch_raw(map, section_key)

      cond do
        raw == :missing and optional? ->
          {acc_fields, acc_errors}

        raw == :missing ->
          {acc_fields,
           [
             %Error{file: path, section: label, message: "missing required section #{label}"}
             | acc_errors
           ]}

        true ->
          case fun.(raw) do
            {:ok, value} -> {Map.put(acc_fields, section_key, value), acc_errors}
            {:error, errs} -> {acc_fields, prepend_section(errs, label, path) ++ acc_errors}
          end
      end
    end)
  end

  defp prepend_section(errs, label, path) do
    Enum.map(errs, fn
      %Error{} = e -> %{e | section: e.section || label, file: e.file || path}
    end)
  end

  defp fetch_raw(map, :node), do: Map.get(map, "node", :missing)
  defp fetch_raw(map, :doc), do: Map.get(map, "doc", :missing)

  defp fetch_raw(map, :ports_in) do
    case get_in(map, ["ports", "in"]) do
      nil -> :missing
      v -> v
    end
  end

  defp fetch_raw(map, :ports_out) do
    case get_in(map, ["ports", "out"]) do
      nil -> :missing
      v -> v
    end
  end

  defp fetch_raw(map, :effects), do: Map.get(map, "effects", :missing)
  defp fetch_raw(map, :contract), do: Map.get(map, "contract", :missing)
  defp fetch_raw(map, :observability), do: Map.get(map, "observability", :missing)

  defp cast_node_meta(%{"id" => id, "version" => v, "kind" => k}) do
    case Node.cast_kind(k) do
      {:ok, kind} -> {:ok, %{id: id, version: v, kind: kind}}
      :error -> {:error, [%Error{message: "unknown node kind #{inspect(k)}"}]}
    end
  end

  defp cast_node_meta(map) do
    missing =
      ["id", "version", "kind"]
      |> Enum.reject(&Map.has_key?(map, &1))
      |> Enum.map(&%Error{message: "missing required key #{&1}"})

    {:error, missing}
  end

  defp cast_doc(map),
    do: {:ok, %Doc{intent: Map.get(map, "intent"), owner: Map.get(map, "owner")}}

  defp cast_ports(map, label) when is_map(map) do
    {ports, errors} =
      Enum.reduce(map, {%{}, []}, fn {name, opts}, {acc, errs} ->
        case cast_port(name, opts) do
          {:ok, port} -> {Map.put(acc, port.name, port), errs}
          {:error, e} -> {acc, [%Error{section: "#{label}.#{name}", message: e} | errs]}
        end
      end)

    if errors == [], do: {:ok, ports}, else: {:error, errors}
  end

  defp cast_ports(_map, label),
    do: {:error, [%Error{section: label, message: "expected a table"}]}

  defp cast_port(name, opts) when is_map(opts) do
    case Map.fetch(opts, "schema") do
      {:ok, schema} when is_binary(schema) ->
        {:ok,
         %Port{
           name: String.to_atom(name),
           schema: schema,
           buffer: Map.get(opts, "buffer")
         }}

      _ ->
        {:error, "missing or invalid schema"}
    end
  end

  defp cast_port(_name, _), do: {:error, "expected a table with a schema key"}

  defp cast_effects(map) when is_map(map) do
    effects = %Effects{
      http: cast_http(Map.get(map, "http")),
      db: cast_db(Map.get(map, "db")),
      time: Map.get(map, "time"),
      random: Map.get(map, "random")
    }

    {:ok, effects}
  end

  defp cast_effects(_), do: {:error, [%Error{message: "expected a table"}]}

  defp cast_http(nil), do: nil

  defp cast_http(%{"allow" => allow, "methods" => methods})
       when is_list(allow) and is_list(methods),
       do: %{allow: allow, methods: Enum.map(methods, &String.upcase/1)}

  defp cast_http(%{"allow" => allow}) when is_list(allow),
    do: %{allow: allow, methods: ["GET", "POST", "PUT", "DELETE", "PATCH"]}

  defp cast_http(_), do: nil

  defp cast_db(nil), do: nil
  defp cast_db(%{"allow" => allow}) when is_list(allow), do: %{allow: allow}
  defp cast_db(_), do: nil

  defp cast_contract(map) when is_map(map) do
    with {:ok, pure} <- cast_mfa(Map.get(map, "pure_core"), 2),
         {:ok, shell} <- cast_mfa(Map.get(map, "effect_shell"), 2) do
      {:ok,
       %Contract{
         pure_core: pure,
         effect_shell: shell,
         retry: cast_retry(Map.get(map, "retry")),
         timeout_ms: Map.get(map, "timeout_ms"),
         idempotency: cast_idempotency(Map.get(map, "idempotency"))
       }}
    end
  end

  defp cast_contract(_), do: {:error, [%Error{message: "expected a table"}]}

  defp cast_mfa(nil, _), do: {:error, [%Error{message: "missing pure_core or effect_shell"}]}

  defp cast_mfa(ref, default_arity) when is_binary(ref) do
    case String.split(ref, "/", parts: 2) do
      [mf, arity_s] ->
        with {arity, ""} <- Integer.parse(arity_s),
             {:ok, mod, fun} <- split_mod_fun(mf) do
          {:ok, %{module: mod, function: fun, arity: arity}}
        else
          _ -> {:error, [%Error{message: "invalid function ref #{inspect(ref)}"}]}
        end

      [mf] ->
        case split_mod_fun(mf) do
          {:ok, mod, fun} -> {:ok, %{module: mod, function: fun, arity: default_arity}}
          :error -> {:error, [%Error{message: "invalid function ref #{inspect(ref)}"}]}
        end
    end
  end

  defp cast_mfa(_, _), do: {:error, [%Error{message: "function ref must be a string"}]}

  defp split_mod_fun(mf) do
    case String.split(mf, ".") do
      parts when length(parts) >= 2 ->
        {mod_parts, [fun]} = Enum.split(parts, -1)
        {:ok, Module.concat(mod_parts), String.to_atom(fun)}

      _ ->
        :error
    end
  end

  defp cast_retry(nil), do: nil

  defp cast_retry(map) when is_map(map),
    do: %{
      strategy: Map.get(map, "strategy", "none"),
      max: Map.get(map, "max", 0),
      on: Map.get(map, "on", []),
      base_ms: Map.get(map, "base_ms")
    }

  defp cast_idempotency(nil), do: nil
  defp cast_idempotency(%{"key" => k}), do: %{key: k}
  defp cast_idempotency(_), do: nil

  defp cast_observability(map) when is_map(map) do
    {:ok,
     %{
       metrics: Map.get(map, "metrics", []),
       traces: Map.get(map, "traces", "off")
     }}
  end

  defp cast_observability(_), do: {:ok, %{}}

  # ---------- network cast ----------

  defp cast_network(map, path, visited) do
    base_dir = Path.dirname(path)

    meta = Map.get(map, "network", %{})

    nodes_raw = Map.get(map, "nodes", %{})
    edges_raw = Map.get(map, "edges", [])
    expose_raw = Map.get(map, "expose", %{})
    sup_raw = Map.get(map, "supervision", %{})
    deploy_raw = Map.get(map, "deploy", %{})

    # cast_network_nodes flattens any subgraph (`use` -> network) into namespaced
    # leaf nodes, returning a subgraph index (for edge rewriting) + the subgraphs'
    # own internal edges.
    {nodes, subgraph_index, sub_edges, node_errors} =
      cast_network_nodes(nodes_raw, base_dir, path, visited)

    {edges, edge_errors} = cast_edges(edges_raw, path)
    {rewritten_edges, rewrite_errors} = rewrite_subgraph_edges(edges, subgraph_index, path)
    {expose, expose_errors} = cast_expose(expose_raw, path)
    {expose, expose_rewrite_errors} = rewrite_subgraph_expose(expose, subgraph_index, path)
    {sup, sup_errors} = cast_supervision(sup_raw, path)
    deploy = cast_deploy(deploy_raw)

    meta_errors = check_network_meta(meta, path)

    errors =
      meta_errors ++
        node_errors ++
        edge_errors ++ rewrite_errors ++ expose_errors ++ expose_rewrite_errors ++ sup_errors

    if errors == [] do
      {:ok,
       %Network{
         path: path,
         id: meta["id"],
         version: meta["version"],
         runtime: Map.get(meta, "runtime", "beam"),
         nodes: nodes,
         edges: rewritten_edges ++ sub_edges,
         expose: expose,
         supervision: sup,
         deploy: deploy
       }}
    else
      {:error, errors}
    end
  end

  defp check_network_meta(map, path) when is_map(map) do
    for key <- ["id", "version"],
        not Map.has_key?(map, key),
        do: %Error{file: path, section: "[network]", message: "missing required key #{key}"}
  end

  defp check_network_meta(_, path),
    do: [%Error{file: path, section: "[network]", message: "missing [network] section"}]

  # Returns {flat_nodes, subgraph_index, sub_edges, errors}. A subgraph `use`
  # contributes namespaced leaf nodes (merged into flat_nodes), an entry in the
  # subgraph_index (exposed-port -> internal endpoint, for edge rewriting), and
  # its own internal edges (already namespaced) into sub_edges.
  defp cast_network_nodes(map, base_dir, network_path, visited) when is_map(map) do
    Enum.reduce(map, {%{}, %{}, [], []}, fn {local_name, spec},
                                            {nodes, subidx, sub_edges, errs} ->
      local_id = String.to_atom(local_name)

      case cast_one_network_node(local_id, spec, base_dir, network_path, visited) do
        {:ok, {:leaf, node}} ->
          {Map.put(nodes, local_id, node), subidx, sub_edges, errs}

        {:ok, {:subgraph, sg}} ->
          {Map.merge(nodes, sg.nodes), Map.put(subidx, local_id, %{in: sg.in, out: sg.out}),
           sub_edges ++ sg.edges, errs}

        {:error, e} ->
          {nodes, subidx, sub_edges, e ++ errs}
      end
    end)
  end

  defp cast_one_network_node(local_id, %{"use" => use_path} = spec, base_dir, network_path, visited) do
    resolved =
      if Path.type(use_path) == :absolute,
        do: use_path,
        else: Path.expand(use_path, base_dir)

    config = Map.get(spec, "config", %{})

    case classify_manifest(resolved) do
      {:node, node_map} ->
        cast_leaf_node(local_id, node_map, resolved, config)

      {:network, net_map} ->
        cond do
          map_size(config) > 0 ->
            {:error,
             [
               err(network_path, "[nodes].#{local_id}",
                 "config overlay on a subgraph (`use` = network) is not supported")
             ]}

          MapSet.member?(visited, Path.expand(resolved)) ->
            {:error,
             [
               err(network_path, "[nodes].#{local_id}",
                 "subgraph composition cycle: #{inspect(resolved)} is already in the chain")
             ]}

          true ->
            expand_subgraph(local_id, net_map, resolved, network_path, visited)
        end

      {:error, errs} ->
        {:error, prefix_section(errs, "[nodes].#{local_id}")}
    end
  end

  defp cast_one_network_node(local_id, _, _, network_path, _visited) do
    {:error,
     [err(network_path, "[nodes].#{local_id}", "expected { use = \"path/to/(node|network).bloccs\" }")]}
  end

  defp cast_leaf_node(local_id, node_map, resolved, config) do
    case cast_node(node_map, resolved) do
      {:ok, manifest} ->
        {:ok,
         {:leaf, %NetworkNode{local_id: local_id, use_path: resolved, manifest: manifest, config: config}}}

      {:error, errs} ->
        {:error, prefix_section(errs, "[nodes].#{local_id}")}
    end
  end

  # Flatten a sub-network into namespaced leaf nodes + edges, and a resolution
  # map from the subgraph's exposed ports to its (namespaced) internal endpoints.
  defp expand_subgraph(local_id, net_map, resolved, network_path, visited) do
    case cast_network(net_map, resolved, MapSet.put(visited, Path.expand(resolved))) do
      {:ok, sub} ->
        case check_expose_targets(sub, network_path, local_id) do
          [] ->
            ns_nodes =
              Map.new(sub.nodes, fn {id, nn} ->
                nsid = ns_id(local_id, id)
                {nsid, %{nn | local_id: nsid}}
              end)

            ns_edges = Enum.map(sub.edges, &namespace_edge(&1, local_id))

            {:ok,
             {:subgraph,
              %{
                nodes: ns_nodes,
                edges: ns_edges,
                in: resolve_expose(sub.expose.in, local_id),
                out: resolve_expose(sub.expose.out, local_id)
              }}}

          errors ->
            {:error, errors}
        end

      {:error, errs} ->
        {:error, prefix_section(errs, "[nodes].#{local_id}")}
    end
  end

  # The subgraph must expose at least one in *and* one out, and every exposed
  # endpoint must reference a real internal node port.
  defp check_expose_targets(%Network{} = sub, network_path, local_id) do
    in_errs = expose_target_errors(sub, sub.expose.in, :ports_in, network_path, local_id, "in")
    out_errs = expose_target_errors(sub, sub.expose.out, :ports_out, network_path, local_id, "out")

    empties =
      cond do
        map_size(sub.expose.in) == 0 ->
          [err(network_path, "[nodes].#{local_id}", "subgraph exposes no [expose.in] ports")]

        map_size(sub.expose.out) == 0 ->
          [err(network_path, "[nodes].#{local_id}", "subgraph exposes no [expose.out] ports")]

        true ->
          []
      end

    empties ++ in_errs ++ out_errs
  end

  defp expose_target_errors(sub, expose_map, ports_key, network_path, local_id, dir) do
    Enum.flat_map(expose_map, fn {exposed, {inner_node, inner_port}} ->
      node = Map.get(sub.nodes, inner_node)

      cond do
        is_nil(node) ->
          [
            err(network_path, "[nodes].#{local_id}",
              "exposed #{dir}-port `#{exposed}` targets unknown node `#{inner_node}`")
          ]

        not Map.has_key?(Map.fetch!(node.manifest, ports_key), inner_port) ->
          [
            err(network_path, "[nodes].#{local_id}",
              "exposed #{dir}-port `#{exposed}` targets `#{inner_node}.#{inner_port}`, " <>
                "which is not an #{dir}-port of that node")
          ]

        true ->
          []
      end
    end)
  end

  defp resolve_expose(expose_map, prefix) do
    Map.new(expose_map, fn {exposed, {inner_node, inner_port}} ->
      {exposed, {ns_id(prefix, inner_node), inner_port}}
    end)
  end

  defp ns_id(prefix, id), do: String.to_atom("#{prefix}.#{id}")

  defp namespace_edge(%Edge{from: from, to: tos}, prefix) do
    %Edge{from: ns_endpoint(from, prefix), to: Enum.map(tos, &ns_endpoint(&1, prefix))}
  end

  defp ns_endpoint({node, port}, prefix), do: {ns_id(prefix, node), port}

  # Rewrite parent edges whose endpoints reference a subgraph's exposed ports to
  # the subgraph's real (namespaced) internal endpoints. Leaf endpoints pass through.
  defp rewrite_subgraph_edges(edges, subidx, _path) when map_size(subidx) == 0, do: {edges, []}

  defp rewrite_subgraph_edges(edges, subidx, path) do
    {rev, errs} =
      Enum.reduce(edges, {[], []}, fn %Edge{from: from, to: tos}, {acc, errs} ->
        {new_from, from_errs} = resolve_subgraph_endpoint(from, :out, subidx, path, "[[edges]]")

        {new_tos, to_errs} =
          Enum.reduce(tos, {[], []}, fn ep, {tacc, terrs} ->
            {r, e} = resolve_subgraph_endpoint(ep, :in, subidx, path, "[[edges]]")
            {[r | tacc], terrs ++ e}
          end)

        {[%Edge{from: new_from, to: Enum.reverse(new_tos)} | acc], errs ++ from_errs ++ to_errs}
      end)

    {Enum.reverse(rev), errs}
  end

  # A parent network's own [expose] may reference a child subgraph's exposed
  # ports; resolve those to the namespaced internal endpoints too, so the parent
  # stays composable and the validator sees real ports.
  defp rewrite_subgraph_expose(expose, subidx, _path) when map_size(subidx) == 0, do: {expose, []}

  defp rewrite_subgraph_expose(%Expose{in: ins, out: outs}, subidx, path) do
    {new_in, in_errs} = rewrite_expose_section(ins, :in, subidx, path)
    {new_out, out_errs} = rewrite_expose_section(outs, :out, subidx, path)
    {%Expose{in: new_in, out: new_out}, in_errs ++ out_errs}
  end

  defp rewrite_expose_section(section, dir, subidx, path) do
    Enum.reduce(section, {%{}, []}, fn {name, ep}, {acc, errs} ->
      {resolved, e} = resolve_subgraph_endpoint(ep, dir, subidx, path, "[expose].#{dir}")
      {Map.put(acc, name, resolved), errs ++ e}
    end)
  end

  defp resolve_subgraph_endpoint({node, port} = ep, dir, subidx, path, section) do
    case Map.fetch(subidx, node) do
      :error ->
        {ep, []}

      {:ok, resolution} ->
        res_map = if dir == :in, do: resolution.in, else: resolution.out

        case Map.fetch(res_map, port) do
          {:ok, resolved} ->
            {resolved, []}

          :error ->
            {ep,
             [err(path, section, "subgraph `#{node}` does not expose #{dir}-port `#{port}`")]}
        end
    end
  end

  # Classify a referenced manifest file as a node or network by its top-level table.
  defp classify_manifest(path) do
    with {:ok, text} <- read(path),
         {:ok, map} <- decode(text, path) do
      cond do
        Map.has_key?(map, "network") -> {:network, map}
        Map.has_key?(map, "node") -> {:node, map}
        true -> {:error, [%Error{file: path, message: "manifest has neither [node] nor [network]"}]}
      end
    end
  end

  defp prefix_section(errs, prefix) do
    Enum.map(errs, fn e -> %{e | section: "#{prefix} → #{e.section || ""}"} end)
  end

  defp err(file, section, message),
    do: %Error{file: file, section: section, message: message}

  defp cast_edges(edges, network_path) when is_list(edges) do
    Enum.reduce(edges, {[], []}, fn raw, {acc, errs} ->
      case cast_one_edge(raw) do
        {:ok, edge} ->
          {[edge | acc], errs}

        {:error, msg} ->
          {acc, [%Error{file: network_path, section: "[[edges]]", message: msg} | errs]}
      end
    end)
    |> then(fn {edges, errs} -> {Enum.reverse(edges), Enum.reverse(errs)} end)
  end

  defp cast_edges(_, network_path),
    do:
      {[],
       [%Error{file: network_path, section: "[[edges]]", message: "expected an array of edges"}]}

  defp cast_one_edge(%{"from" => from, "to" => to}) do
    with {:ok, from_endpoint} <- cast_endpoint(from),
         {:ok, to_endpoints} <- cast_to(to) do
      {:ok, %Edge{from: from_endpoint, to: to_endpoints}}
    end
  end

  defp cast_one_edge(_), do: {:error, "edge requires from + to"}

  defp cast_endpoint(s) when is_binary(s) do
    case String.split(s, ".", parts: 2) do
      [node, port] -> {:ok, {String.to_atom(node), String.to_atom(port)}}
      _ -> {:error, "endpoint must be #{inspect("node.port")}"}
    end
  end

  defp cast_endpoint(_), do: {:error, "endpoint must be a string"}

  defp cast_to(s) when is_binary(s) do
    case cast_endpoint(s) do
      {:ok, e} -> {:ok, [e]}
      err -> err
    end
  end

  defp cast_to(list) when is_list(list) do
    endpoints =
      Enum.map(list, fn s ->
        case cast_endpoint(s) do
          {:ok, e} -> e
          {:error, msg} -> {:bad, msg}
        end
      end)

    case Enum.find(endpoints, &match?({:bad, _}, &1)) do
      nil -> {:ok, endpoints}
      {:bad, msg} -> {:error, msg}
    end
  end

  defp cast_to(_), do: {:error, "to must be string or list of strings"}

  defp cast_expose(map, _) when is_map(map) do
    in_map =
      map
      |> Map.get("in", %{})
      |> cast_expose_section()

    out_map =
      map
      |> Map.get("out", %{})
      |> cast_expose_section()

    {%Expose{in: in_map, out: out_map}, []}
  end

  defp cast_expose(_, _), do: {%Expose{}, []}

  defp cast_expose_section(map) when is_map(map) do
    Enum.into(map, %{}, fn {name, endpoint} ->
      {String.to_atom(name), endpoint_pair(endpoint)}
    end)
  end

  defp endpoint_pair(s) when is_binary(s) do
    [n, p] = String.split(s, ".", parts: 2)
    {String.to_atom(n), String.to_atom(p)}
  end

  defp cast_supervision(map, network_path) when is_map(map) do
    case cast_strategy_field(Map.get(map, "strategy")) do
      {:ok, strategy} ->
        sup = %Supervision{
          strategy: strategy,
          max_restarts: Map.get(map, "max_restarts", 3),
          max_seconds: Map.get(map, "max_seconds", 5)
        }

        {sup, []}

      :error ->
        {%Supervision{},
         [
           %Error{
             file: network_path,
             section: "[supervision]",
             message: "unknown supervision strategy #{inspect(Map.get(map, "strategy"))}"
           }
         ]}
    end
  end

  defp cast_supervision(_, _), do: {%Supervision{}, []}

  defp cast_strategy_field(nil), do: {:ok, :one_for_one}
  defp cast_strategy_field(s), do: Supervision.cast_strategy(s)

  defp cast_deploy(map) when is_map(map) do
    concurrency =
      map
      |> Map.get("concurrency", %{})
      |> Enum.into(%{}, fn {k, v} -> {String.to_atom(k), v} end)

    %{concurrency: concurrency, placement: Map.get(map, "placement")}
  end

  defp cast_deploy(_), do: %{concurrency: %{}, placement: nil}
end
