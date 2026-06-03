defmodule Mix.Tasks.Bloccs.New do
  @shortdoc "Scaffold a runnable starter bloccs project"

  @moduledoc """
      mix bloccs.new <name>

  Writes a complete, **runnable** starter mix project under `<name>/`: a mix
  project that depends on `bloccs`, one sample node (manifest + implementation),
  the port schemas it needs, and a one-node network. After scaffolding:

      cd <name>
      mix deps.get
      mix bloccs.run networks/hello.bloccs --message '{"name": "ada"}'

  runs a message end-to-end through the generated Broadway supervision tree.
  """

  use Mix.Task

  @impl Mix.Task
  def run([]), do: Mix.raise("usage: mix bloccs.new <name>")

  def run([name | _]) do
    if File.exists?(name) do
      Mix.raise("path #{name} already exists")
    end

    # `name` may be a path (e.g. `apps/my_flow`); the app atom + module base come
    # from its last segment.
    app = Path.basename(name)
    mod = Macro.camelize(app)

    File.mkdir_p!(Path.join([name, "lib", app]))
    File.mkdir_p!(Path.join([name, "lib", "nodes"]))
    File.mkdir_p!(Path.join(name, "config"))
    File.mkdir_p!(Path.join(name, "nodes"))
    File.mkdir_p!(Path.join(name, "networks"))

    write = fn parts, contents -> File.write!(Path.join([name | parts]), contents) end

    write.(["mix.exs"], mix_exs(app, mod))
    write.(["config", "config.exs"], config_exs())
    write.(["lib", app, "application.ex"], application_ex(mod))
    write.(["lib", app, "schemas.ex"], schemas_ex(mod))
    write.(["lib", "nodes", "hello.ex"], hello_impl(mod))
    write.(["nodes", "hello.bloccs"], hello_node(mod))
    write.(["networks", "hello.bloccs"], hello_network())
    write.(["README.md"], readme(app))

    Mix.shell().info([
      :green,
      "✓ ",
      :reset,
      "created #{name}/ (a runnable bloccs project)",
      "\n\nNext:",
      "\n  cd #{name}",
      "\n  mix deps.get",
      "\n  mix bloccs.validate networks/hello.bloccs",
      "\n  mix bloccs.compile  networks/hello.bloccs",
      "\n  mix bloccs.run      networks/hello.bloccs --message '{\"name\": \"ada\"}'"
    ])
  end

  defp mix_exs(name, mod) do
    """
    defmodule #{mod}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{name},
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: deps()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {#{mod}.Application, []}
        ]
      end

      defp deps do
        [
          {:bloccs, "~> 0.1"}
        ]
      end
    end
    """
  end

  defp config_exs do
    """
    import Config

    # bloccs ships mock HTTP/DB effect backends by default, so this project runs
    # with zero external services. To use real backends, add the deps (e.g. :req,
    # ecto_sql) and select them here — no node code changes:
    #
    #     config :bloccs, :effect_backends,
    #       http: Bloccs.Effects.HTTP.Req,
    #       db:   Bloccs.Effects.DB.Ecto
    """
  end

  defp application_ex(mod) do
    """
    defmodule #{mod}.Application do
      @moduledoc false

      use Application

      @impl true
      def start(_type, _args) do
        # Port schemas must be registered before any message flows.
        #{mod}.Schemas.register()

        Supervisor.start_link([], strategy: :one_for_one, name: #{mod}.Supervisor)
      end
    end
    """
  end

  defp schemas_ex(mod) do
    """
    defmodule #{mod}.Schemas do
      @moduledoc "Versioned port schemas for this project. Registered on app start."

      alias Bloccs.Schema

      def register do
        Schema.register("Name@1", name: :string)
        Schema.register("Greeting@1", message: :string)
        :ok
      end
    end
    """
  end

  defp hello_impl(mod) do
    ~s'''
    defmodule #{mod}.Nodes.Hello do
      use Bloccs.Node, manifest: "../../nodes/hello.bloccs"

      # pure core: no IO, no clock, no randomness — just computation.
      @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
      def transform(req, _ctx) do
        case req["name"] || req[:name] do
          name when is_binary(name) and name != "" ->
            {:ok, %{message: "Hello, \#{String.capitalize(name)}!"}}

          _ ->
            {:error, :invalid_name}
        end
      end

      # effect shell: the only place that would touch the world. This node is
      # pure, so it just emits on its `reply` out-port.
      @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
      def execute(reply, _ctx), do: {:emit, :reply, reply}
    end
    '''
  end

  defp hello_node(mod) do
    """
    [node]
    id      = "hello"
    version = "0.1.0"
    kind    = "transform"

    [doc]
    intent = "Greet a name."

    [ports.in]
    greeting = { schema = "Name@1" }

    [ports.out]
    reply = { schema = "Greeting@1" }

    # No external world touched — an empty [effects] block.
    [effects]

    [contract]
    pure_core    = "#{mod}.Nodes.Hello.transform/2"
    effect_shell = "#{mod}.Nodes.Hello.execute/2"
    """
  end

  defp hello_network do
    """
    [network]
    id      = "hello"
    version = "0.1.0"
    runtime = "beam"

    [nodes]
    greeter = { use = "../nodes/hello.bloccs" }

    # No edges yet — single-node network. Add `[[edges]]` entries when you
    # wire greeter.reply to a downstream node.

    [expose]
    in  = { entry = "greeter.greeting" }
    out = { exit  = "greeter.reply" }

    [supervision]
    strategy = "one_for_one"
    """
  end

  defp readme(name) do
    """
    # #{name}

    A starter [bloccs](https://github.com/Bloccs/bloccs) project: one node and a
    one-node network, ready to run.

    ## Run it

    ```sh
    mix deps.get
    mix bloccs.validate networks/hello.bloccs
    mix bloccs.compile  networks/hello.bloccs
    mix bloccs.run      networks/hello.bloccs --message '{"name": "ada"}'
    ```

    `mix bloccs.run` boots the app (registering the port schemas), compiles the
    network to a Broadway supervision tree under `_build/`, and feeds the JSON
    message into the exposed `entry` port.

    ## Layout

    - `nodes/hello.bloccs` — the node manifest (ports, schemas, contract)
    - `lib/nodes/hello.ex` — its implementation (pure core + effect shell)
    - `lib/#{name}/schemas.ex` — versioned port schemas, registered on app start
    - `networks/hello.bloccs` — wires the node into a runnable network

    See the [bloccs guides](https://github.com/Bloccs/bloccs/tree/main/app/bloccs/guides)
    for the full walkthrough.
    """
  end
end
