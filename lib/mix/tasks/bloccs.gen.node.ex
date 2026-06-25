defmodule Mix.Tasks.Bloccs.Gen.Node do
  @shortdoc "Generate a node (manifest + implementation) in an existing app"

  @moduledoc """
      mix bloccs.gen.node <name> [--kind <kind>] [--module <Base>]

  Adds one node to the **current** Mix project: a manifest at
  `nodes/<name>.bloccs` and its implementation at `lib/nodes/<name>.ex` (a pure
  core and an effect shell). Unlike `mix bloccs.new`, which scaffolds a whole new
  project, this drops a node into an app you already have.

  ## Options

    * `--kind` — `transform` (default), `source`, `sink`, or `router`. Determines
      the port skeleton and the effect-shell return:
      transform/source/router emit, a sink consumes (`:drop`).
    * `--module` — the base module for the generated node
      (`<Base>.Nodes.<Name>`). Defaults to the current app's camelized name.

  ## Examples

      mix bloccs.gen.node enrich
      mix bloccs.gen.node ingest --kind source
      mix bloccs.gen.node route --kind router --module MyApp

  After generating, register the port schemas the node references (see your
  app's schema-registration module) and wire it into a network — write one by
  hand or run `mix bloccs.gen.network`.
  """

  use Mix.Task

  @kinds ~w(transform source sink router)

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [kind: :string, module: :string])

    name =
      case argv do
        [name | _] -> name
        [] -> Mix.raise("usage: mix bloccs.gen.node <name> [--kind <kind>] [--module <Base>]")
      end

    kind = opts[:kind] || "transform"

    unless kind in @kinds do
      Mix.raise("unknown --kind #{inspect(kind)}; one of: #{Enum.join(@kinds, ", ")}")
    end

    slug = Macro.underscore(name)
    node_mod = "#{base_module(opts)}.Nodes.#{Macro.camelize(slug)}"

    manifest_path = Path.join("nodes", "#{slug}.bloccs")
    impl_path = Path.join(["lib", "nodes", "#{slug}.ex"])

    for path <- [manifest_path, impl_path], File.exists?(path) do
      Mix.raise("path #{path} already exists — refusing to overwrite")
    end

    File.mkdir_p!("nodes")
    File.mkdir_p!(Path.join("lib", "nodes"))
    File.write!(manifest_path, manifest(slug, kind, node_mod))
    File.write!(impl_path, impl(slug, kind, node_mod))

    Mix.shell().info([
      :green,
      "✓ ",
      :reset,
      "generated node #{slug} (#{kind})",
      "\n  ",
      :cyan,
      manifest_path,
      :reset,
      " — manifest (ports, effects, contract)",
      "\n  ",
      :cyan,
      impl_path,
      :reset,
      " — #{node_mod} (pure core + effect shell)",
      "\n\nNext:",
      "\n  • register the port schemas it references (e.g. Input@1, Output@1)",
      "\n  • wire it into a network — by hand or `mix bloccs.gen.network`",
      "\n  • `mix bloccs.validate nodes/#{slug}.bloccs`"
    ])
  end

  defp base_module(opts) do
    case opts[:module] do
      nil ->
        case Mix.Project.config()[:app] do
          nil ->
            Mix.raise("not inside a Mix project — pass --module <Base>")

          app ->
            Macro.camelize(to_string(app))
        end

      mod ->
        mod
    end
  end

  # ── Manifest ────────────────────────────────────────────────────────────

  defp manifest(slug, kind, node_mod) do
    """
    [node]
    id      = "#{slug}"
    version = "0.1.0"
    kind    = "#{kind}"

    [doc]
    intent = "TODO: what this node is for."
    #{ports(kind)}
    # Declare only the capabilities this node needs; an undeclared axis is denied.
    # http = { allow = ["api.example.com"], methods = ["GET"] }
    [effects]

    [contract]
    pure_core    = "#{node_mod}.transform/2"
    effect_shell = "#{node_mod}.execute/2"
    """
  end

  # Every node declares both port sections (a source's in-port is its intake, a
  # sink's out-port section stays empty since it emits nothing). The parser
  # requires both headers to be present.
  defp ports("sink") do
    """

    [ports.in]
    input = { schema = "Input@1" }

    [ports.out]
    """
  end

  defp ports("router") do
    """

    [ports.in]
    input = { schema = "Input@1" }

    [ports.out]
    primary   = { schema = "Output@1" }
    secondary = { schema = "Output@1" }
    """
  end

  defp ports(_transform) do
    """

    [ports.in]
    input = { schema = "Input@1" }

    [ports.out]
    output = { schema = "Output@1" }
    """
  end

  # ── Implementation ──────────────────────────────────────────────────────

  defp impl(slug, kind, node_mod) do
    """
    defmodule #{node_mod} do
      @moduledoc "TODO: describe this node."

      use Bloccs.Node, manifest: "../../nodes/#{slug}.bloccs"

    #{body(kind)}
    end
    """
  end

  # transform / source: compute in the pure core, emit on the out-port.
  defp body(kind) when kind in ["transform", "source"] do
    """
      # Pure core: no IO, no clock, no randomness — deterministic and easy to test.
      @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
      def transform(payload, _ctx), do: {:ok, payload}

      # Effect shell: the only place allowed to touch the world, and only through
      # declared effects. Emits the result on the `output` out-port.
      @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()} | {:error, term()}
      def execute(payload, _ctx), do: {:emit, :output, payload}\
    """
  end

  # router: the pure core decides; the shell emits on the chosen out-port.
  defp body("router") do
    """
      # Pure core: decide where this message goes. Touches nothing.
      @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
      def transform(payload, _ctx), do: {:ok, payload}

      # Effect shell: emit on one of the declared out-ports.
      @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()} | {:error, term()}
      def execute(payload, _ctx) do
        # TODO: branch on the payload to pick a port.
        {:emit, :primary, payload}
      end\
    """
  end

  # sink: terminal — consume the message and emit nothing (`:drop`).
  defp body("sink") do
    """
      # Pure core: prepare the value to be written out.
      @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
      def transform(payload, _ctx), do: {:ok, payload}

      # Effect shell: write to the outside world through a declared effect, then
      # `:drop` — a sink is terminal and emits nothing downstream.
      @spec execute(map(), Bloccs.Context.t()) :: :drop | {:error, term()}
      def execute(_payload, _ctx), do: :drop\
    """
  end
end
