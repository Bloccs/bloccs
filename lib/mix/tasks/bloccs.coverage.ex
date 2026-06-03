defmodule Mix.Tasks.Bloccs.Coverage do
  @shortdoc "Report structural coverage for a network"

  @moduledoc """
      mix bloccs.coverage <network.bloccs> [--message <json>] [--trace <file>] [--port <name>] [--wait <secs>]

  Reports structural coverage — every in-port, out-port, and edge — against a
  *reached* set:

    * `--message <json>` runs the network live, feeds one message into the
      exposed intake port, records a trace, and reports what was reached.
    * `--trace <file>` loads a previously recorded `.bloccs-trace` and reports
      against it.
    * with neither, reports the pure structural enumeration (0 reached).
  """

  use Mix.Task

  alias Bloccs.{Compiler, Coverage, Parser, Producer, Router, Trace, Validator}

  @impl Mix.Task
  def run([]), do: Mix.raise("usage: mix bloccs.coverage <network.bloccs> [--message <json>]")

  def run([path | _] = args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [message: :string, trace: :string, port: :string, wait: :integer]
      )

    {:ok, _} = Application.ensure_all_started(:bloccs)

    with {:ok, network} <- Parser.parse_network(path),
         :ok <- Validator.validate_network(network) do
      reached = reached_for(network, opts)
      report = Coverage.report(network, reached)
      Mix.shell().info(Coverage.render(network, report))
    else
      {:error, errs} ->
        Enum.each(errs, &Mix.shell().error("  - #{inspect(&1)}"))
        exit({:shutdown, 1})
    end
  end

  defp reached_for(network, opts) do
    cond do
      Keyword.has_key?(opts, :trace) ->
        file = opts[:trace]

        case Trace.load(file) do
          {:ok, events} -> Trace.reached(events)
          {:error, reason} -> Mix.raise("could not load trace #{file}: #{inspect(reason)}")
        end

      Keyword.has_key?(opts, :message) ->
        reached_from_live_run(network, opts[:message], opts)

      true ->
        []
    end
  end

  defp reached_from_live_run(network, json, opts) do
    payload =
      case Jason.decode(json) do
        {:ok, p} -> p
        {:error, _} -> Mix.raise("--message must be valid JSON")
      end

    Mix.Task.run("app.start")
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    network_id = String.to_atom(network.id)
    rec = Trace.record(network_id)

    {node, port} = resolve_intake(network, Keyword.get(opts, :port))
    _ = Producer.push(Router.producer_name(network_id, node, port), payload)

    Process.sleep(Keyword.get(opts, :wait, 2) * 1000)
    Trace.reached(Trace.stop(rec))
  end

  defp resolve_intake(network, nil) do
    case network.expose.in do
      empty when map_size(empty) == 0 ->
        node = Enum.at(network.nodes, 0) |> elem(1)
        {node.local_id, node.manifest.ports_in |> Map.keys() |> List.first()}

      ins ->
        {_name, endpoint} = Enum.at(ins, 0)
        endpoint
    end
  end

  defp resolve_intake(network, name) do
    case Map.fetch(network.expose.in, String.to_atom(name)) do
      {:ok, endpoint} -> endpoint
      :error -> Mix.raise("no exposed input port `#{name}` in network #{network.id}")
    end
  end
end
