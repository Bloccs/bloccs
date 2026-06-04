defmodule Bloccs.Integration.MergeTest do
  @moduledoc """
  End-to-end proof of fan-in (merge): two source nodes whose out-ports both edge
  into a single collector in-port.

  v0.1 caps a node at one *in-port* (`Validator.check_single_input`), but a port
  may be the target of *many edges* — `Router.build_table` accumulates every
  edge into the port's one producer — so N sources merge into one stream with no
  special construct. Delivery from the two sources is interleaved/unordered.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Producer, Router, Schema, Validator}

  @path Path.expand("../fixtures/merge/merge.bloccs", __DIR__)

  setup_all do
    Schema.clear!()
    Schema.register("Msg@1", id: :string)

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

  test "both sources' edges feed the single collector in-port" do
    Router.register_sink(:merge, :collect, :done, self())

    :ok = Producer.push(Router.producer_name(:merge, :left, :req), %{"id" => "from-left"})
    :ok = Producer.push(Router.producer_name(:merge, :right, :req), %{"id" => "from-right"})

    assert_receive {:bloccs_sink, :merge, :collect, :done, %{"id" => "from-left"}}, 1_000
    assert_receive {:bloccs_sink, :merge, :collect, :done, %{"id" => "from-right"}}, 1_000
  end

  test "the validator accepts two distinct edges into one in-port" do
    {:ok, network} = Parser.parse_network(@path)
    assert :ok = Validator.validate_network(network)

    # Two distinct edges share the same target endpoint (collect.acc).
    targets = Enum.flat_map(network.edges, & &1.to)
    assert Enum.count(targets, &(&1 == {:collect, :acc})) == 2
  end
end
