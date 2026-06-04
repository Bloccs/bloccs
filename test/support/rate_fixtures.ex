defmodule Bloccs.Integration.RateFixtures do
  @moduledoc """
  Pass-through node impls for the throttle/delay integration test: `limited`
  declares `[rate]` (Broadway rate limiting) and `[delay]` (a producer delay),
  and forwards each message to `Sink`.
  """

  defmodule Limited do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/rate/limited.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end

  defmodule Sink do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/rate/sink.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end
end
