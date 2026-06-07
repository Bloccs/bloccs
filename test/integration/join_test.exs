defmodule Bloccs.Integration.JoinTest do
  @moduledoc """
  End-to-end proof of a correlated multi-input join. `reconcile` is a `[join]`
  node with two distinct typed in-ports (`left: Order@1`, `right: Payment@1`),
  each compiled to its own pipeline. Arrivals are correlated by `order_id` in the
  `Bloccs.Join` buffer; a matched pair emits one joined record, and an unmatched
  side is deadlettered after the timeout.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Join, Parser, Producer, Router, Schema, Validator}

  @path Path.expand("../fixtures/join/join.bloccs", __DIR__)

  setup_all do
    Schema.clear!()
    Schema.register("Order@1", order_id: :string, item: :string)
    Schema.register("Payment@1", order_id: :string, amount: :integer)
    Schema.register("Reconciled@1", order_id: :string, amount: :integer)
    Schema.register("Unmatched@1", key: :string, present: {:list, :string}, payloads: :map)

    {:ok, network} = Parser.parse_network(@path)
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  setup do
    Join.reset()
    :ok
  end

  defp left(p), do: Producer.push(Router.producer_name(:join, :reconcile, :left), p)
  defp right(p), do: Producer.push(Router.producer_name(:join, :reconcile, :right), p)

  test "two sides with the same key emit one joined record" do
    Router.register_sink(:join, :reconcile_sink, :done, self())

    left(%{"order_id" => "o1", "item" => "book"})
    right(%{"order_id" => "o1", "amount" => 30})

    assert_receive {:bloccs_sink, :join, :reconcile_sink, :done,
                    %{"order_id" => "o1", "amount" => 30}},
                   1_000
  end

  test "the joined record's lineage lists both correlated arrivals (fan-in)" do
    handler = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:bloccs, :emit],
      fn _e, _m, meta, _ -> send(test_pid, {:emit, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    left(%{"order_id" => "j1", "item" => "book"})
    right(%{"order_id" => "j1", "amount" => 30})

    # The reconcile node emits the joined record on its `joined` out-port.
    assert_receive {:emit, %{from_node: :reconcile, parents: parents, trace_id: trace}}, 1_000

    # Fan-in: a matched pair => two parents (left + right) and a fresh trace.
    assert length(parents) == 2
    assert is_integer(trace)
    assert trace not in parents
  end

  test "out-of-order arrivals still match (right before left)" do
    Router.register_sink(:join, :reconcile_sink, :done, self())

    right(%{"order_id" => "o3", "amount" => 99})
    left(%{"order_id" => "o3", "item" => "lamp"})

    assert_receive {:bloccs_sink, :join, :reconcile_sink, :done,
                    %{"order_id" => "o3", "amount" => 99}},
                   1_000
  end

  test "an unmatched side is deadlettered after the timeout" do
    Router.register_sink(:join, :dead_sink, :dead, self())

    left(%{"order_id" => "o2", "item" => "pen"})

    # No partner arrives; after the [join].timeout_ms (200ms) the sweep emits the
    # partial to the deadletter port as an envelope.
    Process.sleep(250)
    Join.sweep_now()

    assert_receive {:bloccs_sink, :join, :dead_sink, :dead,
                    %{"key" => "o2", "present" => ["left"]}},
                   1_000
  end
end
