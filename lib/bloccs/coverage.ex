defmodule Bloccs.Coverage do
  @moduledoc """
  v0.1 stub for structural coverage over a parsed network.

  Inspired by Kahani & Bagherzadeh 2026 ("Testing Agentic Workflows with
  Structural Coverage Criteria", arXiv 2605.26521). v0.1 enumerates the
  obligations that a `.bloccs-trace` (v0.4+) will eventually satisfy and
  reports them all as "unreached". When traces land, this module will check
  each obligation against recorded execution.
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
  Build a report against a (currently empty for v0.1) set of reached
  obligations. The full implementation reads a `.bloccs-trace` file in v0.4+.
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

    """
    Coverage report for network `#{id}` (v0.1 stub)
    ------------------------------------------------
    Total obligations: #{total}
    Reached:           #{hit}  (#{percent})
    Unreached:         #{length(unreached)}

    #{render_obligation_list(unreached)}

    Note: v0.1 always reports 0 reached. Trace-based coverage
    (Bloccs.Trace, v0.4+) will populate the reached set.
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
