defmodule Bloccs.Integration.JoinFixtures do
  @moduledoc """
  Node impls for the join integration test. `Reconcile` is a `[join]` node with
  two distinct in-ports (`left: Order@1`, `right: Payment@1`); its `pure_core`
  receives the correlated `%{port => payload}` map and emits the merged record.
  The two sinks re-emit what they receive so a listener can observe them.
  """

  defmodule Reconcile do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/join/reconcile.bloccs"

    # pure_core of a [join] node receives the correlated set, keyed by in-port.
    def transform(%{left: order, right: payment}, _ctx) do
      {:ok, %{"order_id" => order["order_id"], "amount" => payment["amount"]}}
    end

    def execute(reconciled, _ctx), do: {:emit, :joined, reconciled}
  end

  defmodule ReconcileSink do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/join/reconcile_sink.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :done, data}
  end

  defmodule DeadSink do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/join/dead_sink.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :dead, data}
  end
end
