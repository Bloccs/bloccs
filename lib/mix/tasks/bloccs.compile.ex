defmodule Mix.Tasks.Bloccs.Compile do
  @shortdoc "Compile a `.bloccs` network into a Broadway supervision tree"

  @moduledoc """
      mix bloccs.compile path/to/network.bloccs [--dest <dir>] [--no-compile]

  Parses + validates the network, then emits Broadway pipeline source files
  to `--dest` (defaults to `_build/<MIX_ENV>/bloccs_generated/<network_id>`).

  The project is compiled first, so each node's manifest can be compared with
  the one its module was compiled with. A node whose manifest differs from its
  module's embedded manifest fails: it would run with the embedded one.

  ## Options

    * `--dest` - where to write the generated sources.
    * `--no-compile` - do not compile the project, and skip the comparison with
      the compiled node modules.
  """

  use Mix.Task

  alias Bloccs.{Parser, Validator, Compiler}
  alias Mix.Tasks.Bloccs.EmbeddedCheck

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [dest: :string, compile: :boolean])

    case rest do
      [] -> Mix.raise("usage: mix bloccs.compile <network.bloccs> [--dest <dir>] [--no-compile]")
      [path | _] -> compile(path, opts)
    end
  end

  defp compile(path, opts) do
    {:ok, _} = Application.ensure_all_started(:bloccs)
    EmbeddedCheck.prepare(opts)

    with {:ok, network} <- Parser.parse_network(path),
         :ok <- Validator.validate_network(network),
         :ok <- EmbeddedCheck.check(network, opts) do
      dest = Keyword.get(opts, :dest)
      compile_opts = if dest, do: [dest_dir: dest], else: []
      {:ok, %{supervisor: sup, files: files}} = Compiler.compile(network, compile_opts)

      Mix.shell().info([
        :green,
        "✓ ",
        :reset,
        "emitted #{length(files)} files for `#{network.id}`"
      ])

      EmbeddedCheck.note_skipped(opts)
      Mix.shell().info("  supervisor:  #{inspect(sup)}")

      for f <- files do
        Mix.shell().info("    " <> Path.relative_to_cwd(f))
      end
    else
      {:error, errs} -> handle_errors(path, errs)
    end
  end

  @spec handle_errors(Path.t(), [Bloccs.Parser.Error.t() | Bloccs.Validator.Issue.t()]) ::
          no_return()
  defp handle_errors(path, errs) do
    Mix.shell().error("✗ #{path}")

    Enum.each(errs, fn
      %Bloccs.Validator.Issue{scope: s, message: m} -> Mix.shell().error("  - #{s}: #{m}")
      %Bloccs.Parser.Error{section: s, message: m} -> Mix.shell().error("  - #{s}: #{m}")
    end)

    exit({:shutdown, 1})
  end
end
