defmodule Mix.Tasks.Bloccs.Lint do
  @shortdoc "Transitive capability lint of every node in the project"

  @moduledoc """
      mix bloccs.lint

  Compiles the project, then for every bloccs node module (one exporting
  `__bloccs_manifest__/0`) walks its `pure_core` / `effect_shell` **and the
  same-application helpers they call, transitively**, applying the capability
  policy to every reachable call (`Bloccs.Lint.Transitive`).

  The compile-time check in `use Bloccs.Node` only sees a node's own body and
  permits calls into same-app helpers without traversing them. This task closes
  that gap: it is what makes "the declared-effect facade is the only path to the
  world" hold through helper indirection, not just for directly-written calls.
  Run it in CI / `mix check`. Exits non-zero if any node has a transitive
  violation.

  Requires modules compiled with debug info (the default for `dev`/`test`). A
  helper whose BEAM has no abstract code is reported as unanalyzable rather than
  assumed safe.

  Options:

    * `--app APP` — limit to modules of the given OTP application (defaults to
      the current Mix project's `:app`).
  """

  use Mix.Task

  alias Bloccs.Lint.Transitive

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [app: :string])
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:bloccs)

    app =
      case opts[:app] do
        nil -> Mix.Project.config()[:app]
        name -> String.to_atom(name)
      end

    nodes = node_modules(app)

    if nodes == [] do
      Mix.shell().info("bloccs.lint: no node modules found in #{inspect(app)}.")
    else
      results = Enum.map(nodes, fn mod -> {mod, Transitive.lint(mod)} end)
      report(results)
    end
  end

  defp node_modules(app) do
    _ = Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, mods} -> Enum.filter(mods, &node_module?/1)
      _ -> []
    end
  end

  defp node_module?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :__bloccs_manifest__, 0)
  end

  defp report(results) do
    flagged = Enum.reject(results, fn {_mod, vs} -> vs == [] end)
    total = results |> Enum.map(fn {_mod, vs} -> length(vs) end) |> Enum.sum()

    if flagged == [] do
      Mix.shell().info(
        "bloccs.lint: #{length(results)} node(s) clean — every reachable call stays inside the declared capabilities."
      )
    else
      Enum.each(flagged, fn {mod, vs} ->
        Mix.shell().error("\n#{inspect(mod)}:")

        Enum.each(vs, fn v ->
          Mix.shell().error("  [#{v.kind}] #{v.at}\n      #{v.reason}")
        end)
      end)

      Mix.raise(
        "bloccs.lint: #{total} transitive capability violation(s) across #{length(flagged)} node(s). " <>
          "Route the call through a declared effect, or record an exception in the node's [lint] section."
      )
    end
  end
end
