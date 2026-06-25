defmodule Bloccs.Lint.Beam do
  @moduledoc false
  # Reads a single function's call set out of a module's compiled BEAM, via its
  # abstract code chunk. Used by `Bloccs.Lint.Transitive` to follow a node's
  # `pure_core` / `effect_shell` into the same-application helpers they call —
  # the intraprocedural macro pass (`Bloccs.Node.EffectLint`) only sees the node
  # body itself.
  #
  # Works on Erlang Abstract Format (the body AST is already macro-expanded and
  # has fully-qualified module atoms, so no alias resolution is needed). Requires
  # the module to be compiled with debug info (the default in dev/test); a BEAM
  # with no abstract code is reported as `{:error, :no_abstract_code}` so the
  # caller can treat the helper as unanalyzable rather than silently safe.

  @typedoc """
  A call discovered in a function body:

  - `{:remote, module, fun, arity, line}` — `M.f(...)` with literal module + fun
  - `{:local, fun, arity, line}` — `f(...)` within the same module
  - `{:dynamic, line}` — a call whose module or fun is computed (unanalyzable)
  - `{:receive, line}` — a `receive` block
  """
  @type call ::
          {:remote, module(), atom(), arity(), non_neg_integer()}
          | {:local, atom(), arity(), non_neg_integer()}
          | {:dynamic, non_neg_integer()}
          | {:receive, non_neg_integer()}

  @doc """
  The calls made by `module.fun/arity`, from its abstract code.
  `{:ok, [call]}` or `{:error, reason}` (`:no_beam`, `:no_abstract_code`,
  `:not_found`, …).
  """
  @spec calls(module(), atom(), arity()) :: {:ok, [call()]} | {:error, term()}
  def calls(module, fun, arity) do
    with {:ok, forms} <- abstract_forms(module),
         {:ok, clauses} <- function_clauses(forms, fun, arity) do
      {:ok, clauses |> walk([]) |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp abstract_forms(module) do
    case :code.which(module) do
      path when is_list(path) ->
        case :beam_lib.chunks(path, [:abstract_code]) do
          {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} -> {:ok, forms}
          {:ok, {^module, [abstract_code: :no_abstract_code]}} -> {:error, :no_abstract_code}
          {:error, :beam_lib, reason} -> {:error, reason}
        end

      # :in_memory / :cover_compiled / :preloaded / :non_existing
      other ->
        {:error, {:no_beam, other}}
    end
  end

  defp function_clauses(forms, fun, arity) do
    case Enum.find(forms, &match?({:function, _, ^fun, ^arity, _}, &1)) do
      {:function, _, ^fun, ^arity, clauses} -> {:ok, clauses}
      nil -> {:error, :not_found}
    end
  end

  # Walk Erlang Abstract Format collecting calls. Specific call/receive shapes are
  # matched first; every other tuple/list is traversed generically so nothing is
  # missed regardless of the surrounding expression (case, block, match, …).
  defp walk({:call, anno, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}, acc) do
    acc = record(anno, {:remote, mod, fun, length(args), ln(anno)}, acc)
    walk(args, acc)
  end

  defp walk({:call, anno, {:remote, _, mod_ast, fun_ast}, args}, acc) do
    # computed module or fun → unanalyzable dispatch
    walk([mod_ast, fun_ast | args], record(anno, {:dynamic, ln(anno)}, acc))
  end

  defp walk({:call, anno, {:atom, _, fun}, args}, acc) do
    acc = record(anno, {:local, fun, length(args), ln(anno)}, acc)
    walk(args, acc)
  end

  defp walk({:call, anno, fun_ast, args}, acc) do
    # call of a computed term (e.g. an anonymous fun bound to a var)
    walk([fun_ast | args], record(anno, {:dynamic, ln(anno)}, acc))
  end

  # `fun M:F/A` capture with literal M/F/A → a remote reference.
  defp walk(
         {:fun, anno, {:function, {:atom, _, mod}, {:atom, _, fun}, {:integer, _, arity}}},
         acc
       ) do
    [{:remote, mod, fun, arity, ln(anno)} | acc]
  end

  defp walk({:receive, anno, clauses}, acc), do: walk(clauses, [{:receive, ln(anno)} | acc])

  defp walk({:receive, anno, clauses, timeout, after_body}, acc) do
    walk([clauses, timeout, after_body], [{:receive, ln(anno)} | acc])
  end

  defp walk(tuple, acc) when is_tuple(tuple), do: walk(Tuple.to_list(tuple), acc)
  defp walk(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk/2)
  defp walk(_leaf, acc), do: acc

  # Compiler-generated calls (`map.field` access expands to an
  # `:elixir_erl_pass.no_parens_remote` fallback; `with` / `for` synthesize
  # dispatch) carry `generated: true` and are not author-written effects, so they
  # are not recorded. The author's own calls keep real source locations. (Caveat:
  # an effect injected by a *macro* into a helper is generated and thus invisible
  # here; macro-injected effects in the node body itself are still caught by the
  # intraprocedural pass, which runs post-expansion.)
  defp record(anno, call, acc) do
    if :erl_anno.generated(anno), do: acc, else: [call | acc]
  end

  # Abstract-format line annotations may be an integer, a `{line, column}`
  # tuple, or an `erl_anno` term — normalize to the integer line.
  defp ln(anno), do: :erl_anno.line(anno)
end
