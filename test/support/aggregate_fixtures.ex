defmodule Bloccs.Integration.AggregateFixtures do
  @moduledoc """
  Node impls for the aggregate (batch) integration test. `Rollup` is a `[batch]`
  node: its `pure_core` receives the LIST of events in a batch and reduces them
  to one summary; its `effect_shell` emits that summary once. `Collect` is a
  plain sink that re-emits what it receives so a sink listener can observe it.
  """

  defmodule Rollup do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/aggregate/rollup.bloccs"

    # pure_core of a [batch] node receives the whole batch (a list of payloads).
    def transform(events, _ctx) when is_list(events) do
      {:ok, %{"count" => length(events), "ids" => Enum.map(events, & &1["id"])}}
    end

    def execute(summary, _ctx), do: {:emit, :summary, summary}
  end

  defmodule Collect do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/aggregate/collect.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :done, data}
  end
end
