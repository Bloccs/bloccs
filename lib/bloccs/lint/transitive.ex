defmodule Bloccs.Lint.Transitive do
  @moduledoc false
  # Transitive capability lint for a node.
  #
  # `Bloccs.Node.EffectLint` runs at compile time and checks a node's *own*
  # `pure_core` / `effect_shell` body. It permits calls into same-application
  # helper modules without traversing them, so a body could reach the world
  # through one level of indirection (`MyApp.Helper.persist/1`, where
  # `MyApp.Helper` does `File.write!`). This pass closes that gap: starting from
  # the node's two contract functions, it walks the call graph over same-app
  # helpers (reading their bodies from BEAM abstract code, see `Bloccs.Lint.Beam`)
  # and applies the same capability policy to every reachable call.
  #
  # It runs after compilation (via `mix bloccs.lint`), when every module's BEAM
  # exists. Compilation has already failed on any *direct* body violation, so in
  # practice this surfaces escapes that live in helpers.

  alias Bloccs.Lint.Beam
  alias Bloccs.Node.EffectLint

  @typedoc "A transitive violation: the reachable function and the reason."
  @type violation :: %{kind: :pure_core | :effect_shell, at: String.t(), reason: String.t()}

  @doc """
  Lint a node module's two contract functions transitively. Returns a (possibly
  empty) list of violations. `node_module` must export `__bloccs_manifest__/0`.
  """
  @spec lint(module()) :: [violation()]
  def lint(node_module) do
    manifest = node_module.__bloccs_manifest__()
    app = Application.get_application(node_module)
    lint_cfg = Map.get(manifest, :lint)

    [
      {manifest.contract.pure_core, :pure_core},
      {manifest.contract.effect_shell, :effect_shell}
    ]
    |> Enum.flat_map(fn {ref, kind} ->
      ctx = EffectLint.context(kind, node_module, app, lint_cfg)
      bfs([{ref.module, ref.function, ref.arity}], MapSet.new(), ctx, [])
    end)
    |> Enum.uniq()
  end

  # Breadth-first over the reachable call graph. `visited` keys on {M,F,A} to
  # terminate on recursion and shared helpers.
  defp bfs([], _visited, _ctx, acc), do: Enum.reverse(acc)

  defp bfs([{m, f, a} = key | rest], visited, ctx, acc) do
    if MapSet.member?(visited, key) do
      bfs(rest, visited, ctx, acc)
    else
      visited = MapSet.put(visited, key)

      case Beam.calls(m, f, a) do
        {:ok, calls} ->
          {work, violations} = classify_calls(calls, key, ctx)
          bfs(work ++ rest, visited, ctx, violations ++ acc)

        {:error, reason} ->
          # An unanalyzable helper is a gap, not a pass: report it so the
          # containment claim isn't silently weakened.
          v = %{
            kind: ctx.kind,
            at: mfa(m, f, a),
            reason:
              "could not be analyzed (#{inspect(reason)}); its effects are not statically contained"
          }

          bfs(rest, visited, ctx, [v | acc])
      end
    end
  end

  defp classify_calls(calls, {cm, cf, ca}, ctx) do
    site = mfa(cm, cf, ca)
    {curr_module, _, _} = {cm, cf, ca}

    Enum.reduce(calls, {[], []}, fn call, {work, violations} ->
      case call do
        {:remote, mod, fun, arity, line} ->
          case EffectLint.classify(mod, fun, ctx) do
            :ok ->
              {work, violations}

            {:follow, _} ->
              {[{mod, fun, arity} | work], violations}

            {:deny, reason} ->
              {work,
               [
                 violation(ctx.kind, site, "#{mfa(mod, fun, arity)} (line #{line})", reason)
                 | violations
               ]}
          end

        {:local, fun, arity, _line} ->
          {[{curr_module, fun, arity} | work], violations}

        {:dynamic, line} ->
          {work,
           [
             violation(
               ctx.kind,
               site,
               "(computed call, line #{line})",
               "dynamic dispatch on a computed module/function is not statically analyzable"
             )
             | violations
           ]}

        {:receive, line} ->
          {work,
           [
             violation(
               ctx.kind,
               site,
               "(receive, line #{line})",
               "receive blocks are outside the facade (the supervision tree owns concurrency)"
             )
             | violations
           ]}
      end
    end)
  end

  # `at` names the reachable helper function being analyzed; `reason` carries the
  # offending call (and line) plus why it's denied.
  defp violation(kind, site, call_desc, reason) do
    %{kind: kind, at: site, reason: "#{call_desc}: #{reason}"}
  end

  defp mfa(mod, fun, arity), do: "#{inspect(mod)}.#{fun}/#{arity}"
end
