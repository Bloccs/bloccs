defmodule Mix.Tasks.Tour.Branching do
  @shortdoc "Tour rung 3 — a router + fan-out (branching, multiple out-ports)"

  @moduledoc """
      mix tour.branching

  Runs the `branching` network: `classify` routes each message to `ok` or
  `flagged`. An `ok` message fans out to two sinks (archive + ack); a `flagged`
  one goes to review. Pushes a short and a long message and prints the receipts.
  """

  use Mix.Task

  alias Bloccs.{Compiler, Parser, Producer, Router, Validator}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, network} = Parser.parse_network("networks/branching.bloccs")
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    Router.register_sink(:branching, :archive, :archived, self())
    Router.register_sink(:branching, :ack, :acked, self())
    Router.register_sink(:branching, :review, :queued, self())

    Mix.shell().info("network `branching` running\n")

    push(%{id: "m1", text: "looks good"})
    push(%{id: "m2", text: "this message is far too long to pass review"})

    # m1 (short) fans out to archive + ack; m2 (long) goes to review = 3 receipts.
    collect(3)
  end

  defp push(message) do
    Producer.push(Router.producer_name(:branching, :classify, :message), message)
    Mix.shell().info("  → pushed #{message.id} (#{String.length(message.text)} chars)")
  end

  defp collect(0), do: :ok

  defp collect(n) do
    receive do
      {:bloccs_sink, :branching, node, _port, %{id: id, outcome: outcome}} ->
        Mix.shell().info("  ← #{id}: #{outcome} (#{node})")
        collect(n - 1)
    after
      2_000 -> :ok
    end
  end
end
