defmodule Bloccs.Integration.AggregateTest do
  @moduledoc """
  End-to-end proof of aggregation (batch / window). A `[batch]` node (`rollup`)
  collects events into batches via Broadway batchers — flushing at `size` (count
  window) or `timeout_ms` (time window) — and its `pure_core` reduces each batch
  (the list of payloads) to one summary that flows downstream.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Producer, Router, Schema, Validator}

  @path Path.expand("../fixtures/aggregate/aggregate.bloccs", __DIR__)

  setup_all do
    Schema.clear!()
    Schema.register("Event@1", id: :string)
    Schema.register("Summary@1", count: :integer, ids: {:list, :string})

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

  defp push(id),
    do: Producer.push(Router.producer_name(:aggregate, :rollup, :events), %{"id" => id})

  test "a full count window emits one aggregate covering the whole batch" do
    Router.register_sink(:aggregate, :collect, :done, self())

    push("e1")
    push("e2")
    push("e3")

    assert_receive {:bloccs_sink, :aggregate, :collect, :done, %{"count" => 3, "ids" => ids}},
                   1_000

    assert Enum.sort(ids) == ["e1", "e2", "e3"]
  end

  test "a partial window flushes on the batch timeout" do
    Router.register_sink(:aggregate, :collect, :done, self())

    # size is 3, so only the 200ms batch_timeout can flush these two.
    push("p1")
    push("p2")

    assert_receive {:bloccs_sink, :aggregate, :collect, :done, %{"count" => 2}}, 1_000
  end

  test "the compiler emits batchers + a handle_batch/4 for a [batch] node" do
    [src_path] = Path.wildcard("_build/#{Mix.env()}/bloccs_generated/aggregate/nodes/rollup.ex")
    src = File.read!(src_path)

    assert src =~ "batchers: [default: [batch_size: 3, batch_timeout: 200]]"
    assert src =~ "def handle_batch(_, messages, _, _) do"
    assert src =~ "Bloccs.Runtime.process_batch(messages, config())"
  end
end
