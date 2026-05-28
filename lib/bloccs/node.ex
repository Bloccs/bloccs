defmodule Bloccs.Node do
  @moduledoc """
  `use Bloccs.Node, manifest: "path/to/node.bloccs"`

  Reads the manifest at compile time, validates it, confirms the
  `pure_core` / `effect_shell` functions exist with the right arity, and
  exposes the parsed manifest via `__bloccs_manifest__/0`.

  ## Compile-time effect AST check

  The macro walks the body of `effect_shell` after compilation finishes and
  emits a warning (not an error) for any `ctx.effects.X.*` access where `X`
  is not declared in `[effects]`. Promoting the warning to a hard compile
  error is post-v0.1 — for now the runtime capability struct backstops it.

  ## Example

      defmodule MyApp.Charge do
        use Bloccs.Node, manifest: "nodes/charge.bloccs"

        def transform(req, ctx), do: ...
        def execute(intent, ctx), do: ...
      end
  """

  alias Bloccs.{Parser, Validator}

  defmacro __using__(opts) do
    manifest_path = Keyword.fetch!(opts, :manifest)
    caller_file = __CALLER__.file
    base_dir = Path.dirname(caller_file)
    resolved = Path.expand(manifest_path, base_dir)

    case Parser.parse_node(resolved) do
      {:ok, manifest} ->
        case Validator.validate_node(manifest) do
          :ok ->
            emit_node_module(manifest, resolved)

          {:error, issues} ->
            raise CompileError,
              file: caller_file,
              description:
                "bloccs node manifest #{resolved} failed validation:\n" <>
                  format_issues(issues)
        end

      {:error, errs} ->
        raise CompileError,
          file: caller_file,
          description:
            "bloccs node manifest #{resolved} could not be parsed:\n" <>
              format_parser_errors(errs)
    end
  end

  defp emit_node_module(manifest, resolved_path) do
    pure = manifest.contract.pure_core
    shell = manifest.contract.effect_shell
    declared_axes = Bloccs.Manifest.Effects.declared(manifest.effects)

    quote do
      @bloccs_manifest unquote(Macro.escape(manifest))
      @bloccs_manifest_path unquote(resolved_path)
      @bloccs_declared_effects unquote(declared_axes)
      @external_resource unquote(resolved_path)

      @doc "Return the parsed manifest backing this node."
      @spec __bloccs_manifest__() :: Bloccs.Manifest.Node.t()
      def __bloccs_manifest__, do: @bloccs_manifest

      @doc "Return the absolute path of the manifest file."
      @spec __bloccs_manifest_path__() :: String.t()
      def __bloccs_manifest_path__, do: @bloccs_manifest_path

      @doc "Return the list of effect axes declared in `[effects]`."
      @spec __bloccs_declared_effects__() :: [atom()]
      def __bloccs_declared_effects__, do: @bloccs_declared_effects

      @after_compile {Bloccs.Node, :__check_contract__}

      unquote(verify_function_refs(pure, shell))
    end
  end

  defp verify_function_refs(pure, shell) do
    quote do
      @doc false
      def __bloccs_pure_core_ref__, do: unquote(Macro.escape(pure))
      @doc false
      def __bloccs_effect_shell_ref__, do: unquote(Macro.escape(shell))
    end
  end

  @doc false
  def __check_contract__(env, _bytecode) do
    manifest = env.module.__bloccs_manifest__()
    pure = manifest.contract.pure_core
    shell = manifest.contract.effect_shell

    [{pure, "pure_core"}, {shell, "effect_shell"}]
    |> Enum.each(fn {%{module: mod, function: fun, arity: arity}, label} ->
      Code.ensure_loaded?(mod)

      unless function_exported?(mod, fun, arity) do
        IO.warn(
          "bloccs: #{label} function #{inspect(mod)}.#{fun}/#{arity} is not defined " <>
            "(declared in #{env.module.__bloccs_manifest_path__()})",
          env
        )
      end
    end)

    walk_effect_shell_for_undeclared(env, shell, manifest)
  end

  defp walk_effect_shell_for_undeclared(
         env,
         %{module: mod, function: fun, arity: _arity},
         manifest
       )
       when mod == env.module do
    declared = Bloccs.Manifest.Effects.declared(manifest.effects)

    ast = Module.get_definition(env.module, {fun, 2}, :all)

    case ast do
      {:v1, _, _, [{_meta, _args, _guards, body}]} ->
        check_node_for_undeclared_effects(body, declared, env)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp walk_effect_shell_for_undeclared(_env, _shell, _manifest), do: :ok

  defp check_node_for_undeclared_effects(ast, declared, env) do
    {_, used} =
      Macro.prewalk(ast, MapSet.new(), fn node, acc ->
        case node do
          {{:., _, [{{:., _, [{:ctx, _, _}, :effects]}, _, _}, axis]}, _, _}
          when is_atom(axis) ->
            {node, MapSet.put(acc, axis)}

          _ ->
            {node, acc}
        end
      end)

    undeclared = MapSet.difference(used, MapSet.new(declared))

    for axis <- undeclared do
      IO.warn(
        "bloccs: effect #{inspect(axis)} used in effect_shell but not declared in [effects]. " <>
          "Declared: #{inspect(declared)}.",
        env
      )
    end
  end

  defp format_issues(issues) do
    issues
    |> Enum.map(fn %Bloccs.Validator.Issue{scope: s, message: m} ->
      "  - #{s || ""}: #{m}"
    end)
    |> Enum.join("\n")
  end

  defp format_parser_errors(errs) do
    errs
    |> Enum.map(fn %Bloccs.Parser.Error{section: s, message: m} ->
      "  - #{s || ""}: #{m}"
    end)
    |> Enum.join("\n")
  end
end
