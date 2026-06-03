defmodule Mix.Tasks.Tour.Pipeline do
  @shortdoc "Tour rung 2 — two nodes + one HTTP effect (edges, effect shell)"

  @moduledoc """
      mix tour.pipeline

  Runs the two-node `pipeline` network: `accept` (pure) → `define` (HTTP effect).
  The edge carries a schema-typed value between them. The HTTP call uses the mock
  backend, stubbed below — in production you'd point it at a real dictionary host
  via config, with no node-code change.
  """

  use Mix.Task

  alias Bloccs.{Compiler, Parser, Producer, Router, Validator}
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    MockHTTP.reset()

    MockHTTP.stub("GET", "http://dictionary.local/define", fn _ ->
      %{"definition" => "a very large expanse of sea"}
    end)

    {:ok, network} = Parser.parse_network("networks/pipeline.bloccs")
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    Router.register_sink(:pipeline, :define, :definition, self())

    Mix.shell().info("network `pipeline` running\n")

    Producer.push(Router.producer_name(:pipeline, :accept, :request), %{word: "Ocean"})
    Mix.shell().info("  → pushed %{word: \"Ocean\"}")

    receive do
      {:bloccs_sink, :pipeline, :define, :definition, %{word: word, definition: definition}} ->
        Mix.shell().info("  ← #{word}: #{definition}")
    after
      2_000 -> Mix.shell().error("  (no definition within 2s)")
    end
  end
end
