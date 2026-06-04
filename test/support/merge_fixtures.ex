defmodule Bloccs.Integration.MergeFixtures do
  @moduledoc """
  Pass-through node impls for the fan-in (merge) integration test: two source
  nodes whose out-ports both edge into a single collector in-port. Each forwards
  its payload unchanged so the collector's sink listener observes both streams.
  """

  defmodule Left do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/merge/left.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end

  defmodule Right do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/merge/right.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end

  defmodule Collect do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/merge/collect.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :done, data}
  end
end
