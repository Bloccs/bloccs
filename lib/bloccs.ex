defmodule Bloccs do
  @moduledoc """
  A typed declarative IR for Agentic Computation Graphs (ACGs) that compiles
  to a Broadway supervision tree on the BEAM.

  See `Bloccs.Manifest.Node`, `Bloccs.Manifest.Network`, `Bloccs.Parser`,
  `Bloccs.Validator`, and `Bloccs.Compiler` for the v0.1 surface.
  """

  @doc """
  Returns the current bloccs library version.

  ## Examples

      iex> is_binary(Bloccs.version())
      true

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:bloccs, :vsn) |> to_string()
  end
end
