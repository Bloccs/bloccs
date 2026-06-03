defmodule Mix.Tasks.Tour.Hello do
  @shortdoc "Tour rung 1 — one pure node (node, port, schema, the run loop)"

  @moduledoc """
      mix tour.hello

  Runs the one-node `hello` network: parse → validate → compile → run. Pushes a
  name in, prints the greeting that comes out. No effects, no setup.
  """

  use Mix.Task

  alias Bloccs.{Compiler, Parser, Producer, Router, Validator}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, network} = Parser.parse_network("networks/hello.bloccs")
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    Router.register_sink(:hello, :greeter, :reply, self())

    Mix.shell().info("network `hello` running\n")

    Producer.push(Router.producer_name(:hello, :greeter, :greeting), %{name: "ada"})
    Mix.shell().info("  → pushed %{name: \"ada\"}")

    receive do
      {:bloccs_sink, :hello, :greeter, :reply, %{message: message}} ->
        Mix.shell().info("  ← #{message}")
    after
      2_000 -> Mix.shell().error("  (no reply within 2s)")
    end
  end
end
