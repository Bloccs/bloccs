defmodule Mix.Tasks.Bloccs.Gen.Network do
  @shortdoc "Generate a network manifest in an existing app"

  @moduledoc """
      mix bloccs.gen.network <name> [--node <node>]...

  Writes a network manifest at `networks/<name>.bloccs` — the topology that
  wires nodes together. Pass `--node` once per node to seed the `[nodes]` table
  (each references `../nodes/<node>.bloccs`); edges and exposed ports are left as
  commented guidance for you to fill in, since they depend on each node's ports.

  ## Examples

      mix bloccs.gen.network pipeline
      mix bloccs.gen.network events --node ingest --node enrich --node persist

  Generate the nodes themselves with `mix bloccs.gen.node`. Validate the result
  with `mix bloccs.validate networks/<name>.bloccs`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [node: :keep])

    name =
      case argv do
        [name | _] -> name
        [] -> Mix.raise("usage: mix bloccs.gen.network <name> [--node <node>]...")
      end

    slug = Macro.underscore(name)
    nodes = opts |> Keyword.get_values(:node) |> Enum.map(&Macro.underscore/1)

    path = Path.join("networks", "#{slug}.bloccs")

    if File.exists?(path) do
      Mix.raise("path #{path} already exists — refusing to overwrite")
    end

    File.mkdir_p!("networks")
    File.write!(path, manifest(slug, nodes))

    Mix.shell().info([
      :green,
      "✓ ",
      :reset,
      "generated network #{slug}",
      "\n  ",
      :cyan,
      path,
      :reset,
      " — #{node_summary(nodes)}",
      "\n\nNext:",
      "\n  • add nodes with `mix bloccs.gen.node` if you haven't",
      "\n  • fill in the [[edges]] to wire out-ports to in-ports",
      "\n  • `mix bloccs.validate #{path}`"
    ])
  end

  defp node_summary([]), do: "no nodes yet — add a [nodes] entry"
  defp node_summary(nodes), do: "#{length(nodes)} node(s): #{Enum.join(nodes, ", ")}"

  defp manifest(slug, nodes) do
    """
    [network]
    id      = "#{slug}"
    version = "0.1.0"
    runtime = "beam"

    #{nodes_block(nodes)}
    # Wire one out-port to one (or more) in-ports. Endpoints are "node.port".
    # [[edges]]
    # from = "ingest.output"
    # to   = "enrich.input"
    #
    # A list fans out: to = ["persist.input", "notify.input"]

    # Promote internal ports to the network's public ports (used by
    # `mix bloccs.run --port <name>` and as a subgraph).
    # [expose]
    # in  = { entry = "ingest.input" }
    # out = { exit  = "persist.output" }

    [supervision]
    strategy = "one_for_one"
    """
  end

  defp nodes_block([]) do
    """
    [nodes]
    # local_id = { use = "../nodes/<node>.bloccs" }
    """
  end

  defp nodes_block(nodes) do
    entries = Enum.map_join(nodes, "\n", fn n -> ~s(#{n} = { use = "../nodes/#{n}.bloccs" }) end)
    "[nodes]\n#{entries}\n"
  end
end
