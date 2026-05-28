defmodule Mix.Tasks.Bloccs.Run do
  @shortdoc "Compile and start a `.bloccs` network supervision tree"

  @moduledoc """
      mix bloccs.run path/to/network.bloccs [--message <json>] [--port <name>]

  Compiles the network, starts the supervisor, and (optionally) feeds a
  single JSON message into the named exposed input port (defaults to the
  first `[expose].in` entry, or the first port of the first node).

  Without `--message`, the task starts the tree and runs an IEx-like wait
  loop so you can poke at it from outside (use IEx attaches or test scripts).
  """

  use Mix.Task

  alias Bloccs.{Parser, Validator, Compiler, Router, Producer}

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [message: :string, port: :string, wait: :integer]
      )

    case rest do
      [] ->
        Mix.raise(
          "usage: mix bloccs.run <network.bloccs> [--message <json>] [--port <name>] [--wait <secs>]"
        )

      [path | _] ->
        Mix.Task.run("app.start")
        run_network(path, opts)
    end
  end

  defp run_network(path, opts) do
    {:ok, network} = Parser.parse_network(path)
    :ok = Validator.validate_network(network)
    {:ok, sup_module} = Compiler.compile_and_load(network)
    {:ok, _pid} = sup_module.start_link([])

    Mix.shell().info([:green, "✓ ", :reset, "network `#{network.id}` running"])
    print_exposed(network)

    case Keyword.get(opts, :message) do
      nil ->
        secs = Keyword.get(opts, :wait, 5)
        Mix.shell().info("  (waiting #{secs}s for messages; interrupt with ^C)")
        Process.sleep(secs * 1000)

      json ->
        feed_message(network, opts, json)
    end
  end

  defp print_exposed(network) do
    expose = network.expose

    if map_size(expose.in) > 0 do
      Mix.shell().info("  exposed inputs:")

      Enum.each(expose.in, fn {name, {node, port}} ->
        Mix.shell().info("    #{name}  → #{node}.#{port}")
      end)
    end

    if map_size(expose.out) > 0 do
      Mix.shell().info("  exposed outputs:")

      Enum.each(expose.out, fn {name, {node, port}} ->
        Mix.shell().info("    #{name}  ← #{node}.#{port}")
      end)
    end

    :ok
  end

  defp feed_message(network, opts, json) do
    payload =
      case Jason.decode(json) do
        {:ok, p} -> p
        {:error, _} -> Mix.raise("--message must be valid JSON")
      end

    {node, port} = resolve_target_port(network, Keyword.get(opts, :port))
    producer = Router.producer_name(String.to_atom(network.id), node, port)
    Producer.push(producer, payload)

    Mix.shell().info("→ pushed message to #{node}.#{port}")
    Process.sleep(Keyword.get(opts, :wait, 2) * 1000)
  end

  defp resolve_target_port(network, nil) do
    case network.expose.in do
      empty when map_size(empty) == 0 ->
        first_node = Enum.at(network.nodes, 0) |> elem(1)
        first_port = Map.keys(first_node.manifest.ports_in) |> List.first()
        {first_node.local_id, first_port}

      ins ->
        {_name, endpoint} = Enum.at(ins, 0)
        endpoint
    end
  end

  defp resolve_target_port(network, name) do
    expose_atom = String.to_atom(name)

    case Map.fetch(network.expose.in, expose_atom) do
      {:ok, endpoint} -> endpoint
      :error -> Mix.raise("no exposed input port `#{name}` in network #{network.id}")
    end
  end
end
