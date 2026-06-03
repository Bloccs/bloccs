defmodule Tour.Nodes.Define do
  @moduledoc """
  Rung 2, node 2. The effect shell calls an HTTP lookup — the only place that
  touches the world — and emits the definition. It may only reach the host
  declared in `[effects]`.
  """

  use Bloccs.Node, manifest: "../../nodes/define.bloccs"

  alias Bloccs.Effects.HTTP

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(word, _ctx), do: {:ok, word}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()} | {:error, term()}
  def execute(%{word: word}, ctx) do
    case HTTP.get(ctx.effects.http, "http://dictionary.local/define") do
      {:ok, %{"definition" => definition}} ->
        {:emit, :definition, %{word: word, definition: definition}}

      {:ok, other} ->
        {:error, {:unexpected_body, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
