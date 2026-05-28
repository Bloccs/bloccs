defmodule Bloccs.Test.DoubleNode do
  @moduledoc """
  Test fixture node implementation paired with `test/fixtures/nodes/double.bloccs`.
  Doubles an integer input. No effects declared.
  """
  use Bloccs.Node, manifest: "../fixtures/nodes/double.bloccs"

  def transform(%{n: n}, _ctx), do: {:ok, %{n: n * 2}}

  def execute(payload, _ctx), do: {:emit, :out_n, payload}
end
