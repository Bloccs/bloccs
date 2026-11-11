defmodule Bloccs.Integration.ManifestMismatchFixtures do
  @moduledoc """
  Node impls for the embedded-manifest check. `Fetch` is compiled with
  `fetch.bloccs`, which grants HTTP. The `mm_differs` network references
  `fetch_no_effects.bloccs` instead: the same contract, but no effects declared.
  """

  defmodule Fetch do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/manifest_mismatch/fetch.bloccs"
    alias Bloccs.Effects.HTTP

    def transform(data, _ctx), do: {:ok, data}

    def execute(data, ctx) do
      {:ok, response} = HTTP.get(ctx.effects.http, "http://a.local/x")
      {:emit, :out, Map.put(data, :http, response)}
    end
  end

  defmodule Sink do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/manifest_mismatch/sink.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end
end
