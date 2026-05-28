defmodule Mix.Tasks.Bloccs.New do
  @shortdoc "Scaffold a starter bloccs project layout"

  @moduledoc """
      mix bloccs.new <name>

  Writes a starter directory tree under `<name>/` with a single sample node
  and a one-node network so users can immediately run `mix bloccs.validate`
  and `mix bloccs.compile`.
  """

  use Mix.Task

  @impl Mix.Task
  def run([]), do: Mix.raise("usage: mix bloccs.new <name>")

  def run([name | _]) do
    if File.exists?(name) do
      Mix.raise("path #{name} already exists")
    end

    File.mkdir_p!(Path.join(name, "nodes"))
    File.mkdir_p!(Path.join(name, "networks"))

    File.write!(Path.join([name, "nodes", "hello.bloccs"]), hello_node())
    File.write!(Path.join([name, "networks", "hello.bloccs"]), hello_network())

    Mix.shell().info([
      :green,
      "✓ ",
      :reset,
      "created #{name}/",
      "\n  - nodes/hello.bloccs",
      "\n  - networks/hello.bloccs",
      "\n\nNext:",
      "\n  mix bloccs.validate #{name}/networks/hello.bloccs",
      "\n  mix bloccs.compile  #{name}/networks/hello.bloccs"
    ])
  end

  defp hello_node do
    ~s"""
    [node]
    id      = "hello"
    version = "0.1.0"
    kind    = "transform"

    [doc]
    intent = "Say hello."

    [ports.in]
    greeting = { schema = "Greeting@1" }

    [ports.out]
    reply = { schema = "Greeting@1" }

    [effects]

    [contract]
    pure_core    = "MyApp.Nodes.Hello.transform/2"
    effect_shell = "MyApp.Nodes.Hello.execute/2"
    """
  end

  defp hello_network do
    ~s"""
    [network]
    id      = "hello"
    version = "0.1.0"

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
end
