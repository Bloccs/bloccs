defmodule Mix.Tasks.Bloccs.Validate do
  @shortdoc "Validate a `.bloccs` node or network manifest"

  @moduledoc """
      mix bloccs.validate path/to/manifest.bloccs [--no-compile]

  Auto-detects whether the file is a node or network manifest (by looking for
  a top-level `[network]` table). Pretty-prints any errors with file +
  section pointers; exits non-zero if anything fails.

  The project is compiled first, so each manifest can be compared with the one
  its node module was compiled with. A manifest that differs from its module's
  embedded manifest fails: the node would run with the embedded one. A manifest
  whose module does not exist yet is not compared.

  ## Options

    * `--no-compile` - do not compile the project, and skip the comparison with
      the compiled node modules. Use it to validate a manifest before its module
      is written, or while the project does not compile.
  """

  use Mix.Task

  alias Bloccs.{Parser, Validator}
  alias Mix.Tasks.Bloccs.EmbeddedCheck

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [compile: :boolean])

    case rest do
      [] -> Mix.raise("usage: mix bloccs.validate <path> [--no-compile]")
      [path | _] -> validate(path, opts)
    end
  end

  defp validate(path, opts) do
    {:ok, _} = Application.ensure_all_started(:bloccs)

    if not File.exists?(path), do: Mix.raise("file not found: #{path}")

    EmbeddedCheck.prepare(opts)
    if network?(path), do: validate_network(path, opts), else: validate_node(path, opts)
  end

  # Structural validation first; the comparison with the compiled module only
  # runs on a manifest that is valid on its own.
  defp then_check(:ok, manifest, opts), do: EmbeddedCheck.check(manifest, opts)
  defp then_check(error, _manifest, _opts), do: error

  defp network?(path) do
    File.read!(path) =~ ~r/^\s*\[\s*network\s*\]/m
  end

  defp validate_node(path, opts) do
    case Parser.parse_node(path) do
      {:ok, manifest} ->
        case then_check(Validator.validate_node(manifest), manifest, opts) do
          :ok ->
            Mix.shell().info([:green, "✓ ", :reset, path, "  ", :bright, "OK (node)"])
            EmbeddedCheck.note_skipped(opts)
            print_warnings(Validator.warnings(manifest))

          {:error, issues} ->
            Mix.shell().error("✗ #{path}\n" <> format_issues(issues))
            exit({:shutdown, 1})
        end

      {:error, errs} ->
        Mix.shell().error("✗ #{path}\n" <> format_parser_errors(errs))
        exit({:shutdown, 1})
    end
  end

  defp validate_network(path, opts) do
    case Parser.parse_network(path) do
      {:ok, network} ->
        case then_check(Validator.validate_network(network), network, opts) do
          :ok ->
            Mix.shell().info([
              :green,
              "✓ ",
              :reset,
              path,
              "  ",
              :bright,
              "OK (network)",
              :reset,
              "\n",
              "  #{map_size(network.nodes)} nodes · #{length(network.edges)} edges"
            ])

            EmbeddedCheck.note_skipped(opts)
            print_warnings(Validator.warnings(network))

          {:error, issues} ->
            Mix.shell().error("✗ #{path}\n" <> format_issues(issues))
            exit({:shutdown, 1})
        end

      {:error, errs} ->
        Mix.shell().error("✗ #{path}\n" <> format_parser_errors(errs))
        exit({:shutdown, 1})
    end
  end

  defp print_warnings([]), do: :ok

  defp print_warnings(warnings) do
    Mix.shell().info([
      :yellow,
      "  ⚠ #{length(warnings)} parsed-but-unwired field#{if length(warnings) > 1, do: "s", else: ""}:",
      :reset
    ])

    for %Bloccs.Validator.Issue{scope: s, message: m} <- warnings do
      Mix.shell().info([:yellow, "    - #{s}: #{m}", :reset])
    end
  end

  defp format_issues(issues) do
    issues
    |> Enum.map(fn %Bloccs.Validator.Issue{scope: s, message: m, file: f} ->
      "  - #{s || ""}#{if f, do: " (#{Path.relative_to_cwd(f)})", else: ""}: #{m}"
    end)
    |> Enum.join("\n")
  end

  defp format_parser_errors(errs) do
    errs
    |> Enum.map(fn %Bloccs.Parser.Error{section: s, message: m, file: f} ->
      "  - #{s || ""}#{if f, do: " (#{Path.relative_to_cwd(f)})", else: ""}: #{m}"
    end)
    |> Enum.join("\n")
  end
end
