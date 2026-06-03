defmodule Tour.Nodes.Accept do
  @moduledoc """
  Rung 2, node 1. A pure entry node: it downcases the requested word and emits it
  on `word`, which the edge carries to `define`.
  """

  use Bloccs.Node, manifest: "../../nodes/accept.bloccs"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
  def transform(req, _ctx) do
    case req[:word] || req["word"] do
      word when is_binary(word) and word != "" ->
        {:ok, %{word: String.downcase(word)}}

      _ ->
        {:error, :invalid_word}
    end
  end

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(word, _ctx), do: {:emit, :word, word}
end
