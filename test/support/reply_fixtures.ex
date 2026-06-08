defmodule Bloccs.Integration.ReplyFixtures do
  @moduledoc """
  Node impls for the request/response integration test (`Bloccs.call/4` /
  `cast/4`): an `ingest` source forwards the request unchanged to a `price` node
  declared `reply = true`, which doubles `n` into a `total` and emits it on its
  reply out-port. The reply is correlated back to the caller by trace_id.
  """

  defmodule Ingest do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/reply/ingest.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end

  defmodule Price do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/reply/price.bloccs"

    # n == 0 raises in pure_core (an `:execute`-phase terminal failure).
    def transform(%{"n" => 0}, _ctx), do: raise("cannot price zero")
    def transform(%{"n" => n} = data, _ctx), do: {:ok, Map.put(data, "total", n * 2)}

    # A negative total is dropped (filtered): no reply, no error — the caller
    # sees a clean timeout rather than hanging forever.
    def execute(%{"total" => total}, _ctx) when total < 0, do: :drop
    def execute(%{"total" => total}, _ctx), do: {:emit, :reply, %{"total" => total}}
  end
end
