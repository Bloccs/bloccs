defmodule Bloccs.Integration.SubgraphFixtures do
  @moduledoc """
  Pass-through node impls for the subgraph composition integration test. Each
  node forwards its payload unchanged and emits on its single out-port, so a
  message pushed at the top of the composed graph appears at the exposed output.
  """

  defmodule Head do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/subgraph/head.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :go, data}
  end

  defmodule Up do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/subgraph/up.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :mid, data}
  end

  defmodule Down do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/subgraph/down.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :output, data}
  end
end
