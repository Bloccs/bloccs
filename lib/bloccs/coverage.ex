defmodule Bloccs.Coverage do
  @moduledoc """
  Structural coverage over a parsed network.

  Inspired by Kahani & Bagherzadeh 2026 ("Testing Agentic Workflows with
  Structural Coverage Criteria", arXiv 2605.26521). Enumerates the coverage
  obligations of a network — every in-port, out-port, and edge — and checks
  them against a *reached* set produced by `Bloccs.Trace` (recorded live from a
  run, or loaded from a `.bloccs-trace` file). With no reached set it reports a
  pure structural enumeration (everything unreached).
  """

  alias Bloccs.Manifest.{Network, NetworkNode, Edge}

  @type obligation ::
          {:port_in, atom(), atom()}
          | {:port_out, atom(), atom()}
          | {:edge, {atom(), atom()}, {atom(), atom()}}

  @type report :: %{
          obligations: [obligation()],
          reached: [obligation()],
          unreached: [obligation()]
        }

  @doc "Enumerate every coverage obligation in a network."
  @spec obligations(Network.t()) :: [obligation()]
  def obligations(%Network{nodes: nodes, edges: edges}) do
    port_obligations =
      Enum.flat_map(nodes, fn {local_id, %NetworkNode{manifest: m}} ->
        in_ports = Enum.map(m.ports_in, fn {p, _} -> {:port_in, local_id, p} end)
        out_ports = Enum.map(m.ports_out, fn {p, _} -> {:port_out, local_id, p} end)
        in_ports ++ out_ports
      end)

    edge_obligations =
      Enum.flat_map(edges, fn %Edge{from: from, to: tos} ->
        Enum.map(tos, fn to -> {:edge, from, to} end)
      end)

    port_obligations ++ edge_obligations
  end

  @doc """
  Build a report comparing a network's obligations against a `reached` set
  (from `Bloccs.Trace`). Defaults to an empty reached set (structural-only).
  """
  @spec report(Network.t(), [obligation()]) :: report()
  def report(%Network{} = network, reached \\ []) do
    all = obligations(network)
    reached_set = MapSet.new(reached)
    unreached = Enum.reject(all, &MapSet.member?(reached_set, &1))

    %{
      obligations: all,
      reached: reached,
      unreached: unreached
    }
  end

  @doc "Render a human-readable summary for the CLI."
  @spec render(Network.t(), report()) :: String.t()
  def render(%Network{id: id}, %{obligations: all, reached: reached, unreached: unreached}) do
    total = length(all)
    hit = length(reached)
    percent = if total == 0, do: "—", else: "#{Float.round(hit / total * 100, 1)}%"

    unreached_block =
      if unreached == [],
        do: "All obligations reached. ✓",
        else: "Unreached:\n" <> render_obligation_list(unreached)

    """
    Coverage report for network `#{id}`
    ------------------------------------------------
    Total obligations: #{total}
    Reached:           #{hit}  (#{percent})
    Unreached:         #{length(unreached)}

    #{unreached_block}
    """
  end

  defp render_obligation_list(obligations) do
    obligations
    |> Enum.map(&format/1)
    |> Enum.map(&("  • " <> &1))
    |> Enum.join("\n")
  end

  defp format({:port_in, n, p}), do: "port (in)  #{n}.#{p}"
  defp format({:port_out, n, p}), do: "port (out) #{n}.#{p}"
  defp format({:edge, {fn_id, fp}, {tn_id, tp}}), do: "edge       #{fn_id}.#{fp} → #{tn_id}.#{tp}"
end
