defmodule Tour.Nodes.Hello do
  @moduledoc """
  Rung 1. The smallest node there is: a pure core that computes a greeting and an
  effect shell that does nothing but emit. No `[effects]`, no IO.
  """

  use Bloccs.Node, manifest: "../../nodes/hello.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
  def transform(req, _ctx) do
    case req[:name] || req["name"] do
      name when is_binary(name) and name != "" ->
        {:ok, %{message: "Hello, #{String.capitalize(name)}!"}}

      _ ->
        {:error, :invalid_name}
    end
  end

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(reply, _ctx), do: {:emit, :reply, reply}
end
