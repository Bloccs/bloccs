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

      defmodule MyApp.Enrich do
        use Bloccs.Node, manifest: "nodes/enrich.bloccs"

        def transform(event, ctx), do: ...
        def execute(event, ctx), do: ...
      end
  """

  alias Bloccs.{Parser, Validator}

  @known_effect_axes [:http, :db, :time, :random]

  # `walk_effect_shell_for_undeclared/3` and `check_node_for_undeclared_effects/3`
  # are reached via `@after_compile` callbacks on `use Bloccs.Node` users.
  # Dialyzer can't follow that meta-level dispatch, so silence the
  # "unused_fun" complaints.
  @dialyzer {:no_unused,
             walk_effect_shell_for_undeclared: 3, check_node_for_undeclared_effects: 3}

  defmacro __using__(opts) do
    manifest_path = Keyword.fetch!(opts, :manifest)
    caller_file = __CALLER__.file
    base_dir = Path.dirname(caller_file)
    resolved = Path.expand(manifest_path, base_dir)

    case Parser.parse_node(resolved) do
      {:ok, manifest} ->
        case Validator.validate_node(manifest) do
          :ok ->
            emit_unwired_field_warnings(manifest, __CALLER__)
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
         %{module: mod, function: fun, arity: arity},
         manifest
       )
       when mod == env.module do
    declared = Bloccs.Manifest.Effects.declared(manifest.effects)

    case Module.get_definition(env.module, {fun, arity}) do
      {:v1, _kind, _meta, clauses} when is_list(clauses) ->
        bodies = Enum.map(clauses, fn {_meta, _args, _guards, body} -> body end)
        check_node_for_undeclared_effects(bodies, declared, env)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp walk_effect_shell_for_undeclared(_env, _shell, _manifest), do: :ok

  # Uses ExAST.Patcher.find_all to detect direct `ctx.effects.<axis>` access in
  # the effect-shell function body. For each known axis that ISN'T declared in
  # the manifest's `[effects]`, search every clause body; emit IO.warn if a hit
  # is found.
  #
  # Limitations (v0.1, by design):
  #   - Syntactic only — aliasing (`effects = ctx.effects`) is not tracked.
  #     Reach integration (v0.2+) closes this gap with transitive call-graph
  #     analysis. The runtime capability struct backstops the warning either
  #     way: undeclared calls raise `Bloccs.Effects.Denied`.
  #   - Assumes the context parameter is named `ctx`. Bloccs convention.
  defp check_node_for_undeclared_effects(bodies, declared, env) when is_list(bodies) do
    declared_set = MapSet.new(declared)
    candidates = Enum.reject(@known_effect_axes, &MapSet.member?(declared_set, &1))

    candidates
    |> Enum.filter(&effect_axis_referenced?(bodies, &1))
    |> Enum.each(fn axis ->
      IO.warn(
        "bloccs: effect #{inspect(axis)} used in effect_shell but not declared in [effects]. " <>
          "Declared: #{inspect(declared)}.",
        env
      )
    end)
  end

  # The syntactic effect-leak check relies on ExAST, which is a dev/test-only
  # dependency of bloccs — it is NOT present when bloccs is used as a dependency
  # by a downstream app. In that case we skip the compile-time warning entirely;
  # the runtime capability struct still refuses undeclared calls
  # (`Bloccs.Effects.Denied`), which is the actual guarantee. Dynamic dispatch
  # (`apply/3`) keeps the compiler from warning about the optional module.
  defp effect_axis_referenced?(bodies, axis) do
    if Code.ensure_loaded?(ExAST.Patcher) do
      pattern = "ctx.effects.#{axis}"
      Enum.any?(bodies, fn body -> apply(ExAST.Patcher, :find_all, [body, pattern]) != [] end)
    else
      false
    end
  end

  defp emit_unwired_field_warnings(manifest, env) do
    case Validator.warnings(manifest) do
      [] ->
        :ok

      warnings ->
        summary =
          "bloccs node `#{manifest.id}` declares fields not yet wired into the v0.1 runtime:\n" <>
            (warnings
             |> Enum.map(fn %Bloccs.Validator.Issue{scope: s} -> "  - #{s}" end)
             |> Enum.join("\n")) <>
            "\nDeclared values are parsed but ignored. See docs/v0.1-audit.md."

        IO.warn(summary, env)
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
