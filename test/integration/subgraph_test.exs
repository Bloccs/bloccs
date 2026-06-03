defmodule Bloccs.Integration.SubgraphTest do
  @moduledoc """
  End-to-end proof of subgraph composition: a parent network `app` composes the
  sub-network `pipe` (up -> down). The parser flattens it to namespaced leaf
  nodes (`pipe.up`, `pipe.down`); the compiler builds a Broadway tree over the
  flat graph; a message pushed into the exposed `start` port flows
  head -> pipe.up -> pipe.down and emerges at the exposed `done` port.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Producer, Router, Schema, Validator}

  @app_path Path.expand("../fixtures/subgraph/app.bloccs", __DIR__)

  setup_all do
    Schema.clear!()
    Schema.register("Msg@1", id: :string)

    {:ok, network} = Parser.parse_network(@app_path)
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

    %{network: network}
  end

  test "the parent flattens the sub-network into namespaced leaf nodes", %{network: net} do
    assert Map.keys(net.nodes) |> Enum.sort() == [:head, :"pipe.down", :"pipe.up"]

    # head.go was rewritten to the subgraph's exposed entry (pipe.up.input);
    # the sub's internal up.mid -> down.mid is namespaced.
    assert Enum.any?(net.edges, &(&1.from == {:head, :go} and &1.to == [{:"pipe.up", :input}]))

    assert Enum.any?(
             net.edges,
             &(&1.from == {:"pipe.up", :mid} and &1.to == [{:"pipe.down", :mid}])
           )
  end

  test "a message flows through the composed graph to the exposed output" do
    # The exposed `done` port resolves to pipe.down.output.
    Router.register_sink(:app, :"pipe.down", :output, self())

    producer = Router.producer_name(:app, :head, :start)
    :ok = Producer.push(producer, %{"id" => "msg-1"})

    assert_receive {:bloccs_sink, :app, :"pipe.down", :output, %{"id" => "msg-1"}}, 2_000
  end
end
