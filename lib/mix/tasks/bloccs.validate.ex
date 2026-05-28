defmodule Mix.Tasks.Bloccs.Validate do
  @shortdoc "Validate a `.bloccs` node or network manifest"

  @moduledoc """
      mix bloccs.validate path/to/manifest.bloccs

  Auto-detects whether the file is a node or network manifest (by looking for
  a top-level `[network]` table). Pretty-prints any errors with file +
  section pointers; exits non-zero if anything fails.
  """

  use Mix.Task

  alias Bloccs.{Parser, Validator}

  @impl Mix.Task
  def run([]), do: Mix.raise("usage: mix bloccs.validate <path>")

  def run([path | _]) do
    {:ok, _} = Application.ensure_all_started(:bloccs)

    cond do
      not File.exists?(path) ->
        Mix.raise("file not found: #{path}")

      network?(path) ->
        validate_network(path)

      true ->
        validate_node(path)
    end
  end

  defp network?(path) do
    File.read!(path) =~ ~r/^\s*\[\s*network\s*\]/m
  end

  defp validate_node(path) do
    case Parser.parse_node(path) do
      {:ok, manifest} ->
        case Validator.validate_node(manifest) do
          :ok ->
            Mix.shell().info([:green, "✓ ", :reset, path, "  ", :bright, "OK (node)"])
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

  defp validate_network(path) do
    case Parser.parse_network(path) do
      {:ok, network} ->
        case Validator.validate_network(network) do
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
