defmodule Mix.Tasks.Bloccs.Coverage do
  @shortdoc "Report structural coverage obligations for a network (v0.1 stub)"

  @moduledoc """
      mix bloccs.coverage path/to/network.bloccs

  Enumerates every port and edge as a coverage obligation and reports them
  all as unreached. The trace-driven implementation lands in v0.4+ (see
  Bloccs.Coverage).
  """

  use Mix.Task

  alias Bloccs.{Parser, Validator, Coverage}

  @impl Mix.Task
  def run([]), do: Mix.raise("usage: mix bloccs.coverage <network.bloccs>")

  def run([path | _]) do
    {:ok, _} = Application.ensure_all_started(:bloccs)

    with {:ok, network} <- Parser.parse_network(path),
         :ok <- Validator.validate_network(network) do
      report = Coverage.report(network)
      Mix.shell().info(Coverage.render(network, report))
    else
      {:error, errs} ->
        Enum.each(errs, fn issue ->
          Mix.shell().error("  - #{inspect(issue)}")
        end)

        exit({:shutdown, 1})
    end
  end
end
