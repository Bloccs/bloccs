defmodule Mix.Tasks.Tour.Filter do
  @shortdoc "Tour rung 4 — filter (:drop) + split (one node, multiple out-ports)"

  @moduledoc """
      mix tour.filter

  Runs the `filter_split` network. The `gate` node does two new things in one
  place: it **drops** blank messages (a filter — the shell returns `:drop`, so
  the message is consumed and nothing is emitted) and it **splits** every other
  message to BOTH the `kept` and `audit` out-ports in a single invocation, each
  with a distinct payload.

  Pushes two real messages and one blank: each real message produces two
  receipts (kept + audit), and the blank produces none.
  """

  use Mix.Task

  alias Bloccs.{Compiler, Parser, Producer, Router, Validator}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, network} = Parser.parse_network("networks/filter_split.bloccs")
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    Router.register_sink(:filter_split, :keep_sink, :stored, self())
    Router.register_sink(:filter_split, :audit_sink, :logged, self())

    Mix.shell().info("network `filter_split` running\n")

    push(%{id: "m1", text: "ship it"})
    push(%{id: "m2", text: "looks good to me"})
    push(%{id: "m3", text: "   "})

    # Two real messages × (kept + audit) = 4 receipts; the blank is dropped.
    collect(4)
    Mix.shell().info("\n  (m3 was blank → dropped by the filter: no receipts)")
  end

  defp push(%{id: id, text: text} = message) do
    Producer.push(Router.producer_name(:filter_split, :gate, :message), message)
    label = if String.trim(text) == "", do: "blank", else: "#{String.length(text)} chars"
    Mix.shell().info("  → pushed #{id} (#{label})")
  end

  defp collect(0), do: :ok

  defp collect(n) do
    receive do
      {:bloccs_sink, :filter_split, node, _port, %{id: id, outcome: outcome}} ->
        Mix.shell().info("  ← #{id}: #{outcome} (#{node})")
        collect(n - 1)
    after
      2_000 -> :ok
    end
  end
end
