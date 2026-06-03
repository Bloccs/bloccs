defmodule Events.Nodes.Enrich do
  @moduledoc """
  Calls an HTTP lookup to enrich the event, then emits the enriched version.
  The manifest declares the `enrichment.local` HTTP allowlist plus `timeout_ms`,
  `retry`, and `idempotency` — so a replayed webhook (same id) is deduped before
  the lookup is ever made, and a slow/failing lookup is bounded and retried.
  """

  use Bloccs.Node, manifest: "../../nodes/enrich.bloccs"

  alias Bloccs.Effects.HTTP

  @lookup_url "http://enrichment.local/lookup"

  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()}
  def transform(event, _ctx), do: {:ok, event}

  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()} | {:error, term()}
  def execute(event, ctx) do
    case HTTP.get(ctx.effects.http, @lookup_url) do
      {:ok, enrichment} ->
        {:emit, :enriched, Map.put(event, :enrichment, enrichment)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
