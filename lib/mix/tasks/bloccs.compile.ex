defmodule Mix.Tasks.Bloccs.Compile do
  @shortdoc "Compile a `.bloccs` network into a Broadway supervision tree"

  @moduledoc """
      mix bloccs.compile path/to/network.bloccs [--dest <dir>]

  Parses + validates the network, then emits Broadway pipeline source files
  to `--dest` (defaults to `_build/<MIX_ENV>/bloccs_generated/<network_id>`).
  """

  use Mix.Task

  alias Bloccs.{Parser, Validator, Compiler}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [dest: :string])

    case rest do
      [] -> Mix.raise("usage: mix bloccs.compile <network.bloccs> [--dest <dir>]")
      [path | _] -> compile(path, opts)
    end
  end

  defp compile(path, opts) do
    {:ok, _} = Application.ensure_all_started(:bloccs)

    with {:ok, network} <- Parser.parse_network(path),
         :ok <- Validator.validate_network(network) do
      dest = Keyword.get(opts, :dest)
      compile_opts = if dest, do: [dest_dir: dest], else: []
      {:ok, %{supervisor: sup, files: files}} = Compiler.compile(network, compile_opts)

      Mix.shell().info([
        :green,
        "✓ ",
        :reset,
        "emitted #{length(files)} files for `#{network.id}`"
      ])

      Mix.shell().info("  supervisor:  #{inspect(sup)}")

      for f <- files do
        Mix.shell().info("    " <> Path.relative_to_cwd(f))
      end
    else
      {:error, errs} -> handle_errors(path, errs)
    end
  end

  defp handle_errors(path, errs) do
    Mix.shell().error("✗ #{path}")

    Enum.each(errs, fn
      %Bloccs.Validator.Issue{scope: s, message: m} -> Mix.shell().error("  - #{s}: #{m}")
      %Bloccs.Parser.Error{section: s, message: m} -> Mix.shell().error("  - #{s}: #{m}")
    end)

    exit({:shutdown, 1})
  end
end
