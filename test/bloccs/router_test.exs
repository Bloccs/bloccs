defmodule Bloccs.RouterTest do
  @moduledoc """
  Unit tests for `Bloccs.Router` without booting Broadway. We exercise the
  table lookup, sink subscription, and dispatch behaviour with synthetic
  producers (named processes mounted in `Bloccs.Registry`).
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Router, Producer}

  setup do
    network = String.to_atom("rtr_#{:erlang.unique_integer([:positive, :monotonic])}")
    %{net: network}
  end

  test "register stores the edge table and lookup returns targets", %{net: net} do
    edges = [
      {{:a, :out}, [{:b, :in_b}, {:c, :in_c}]},
      {{:b, :out}, [{:c, :other}]}
    ]

    :ok = Router.register(net, edges)
    assert [{:b, :in_b}, {:c, :in_c}] = Router.lookup(net, :a, :out)
    assert [{:c, :other}] = Router.lookup(net, :b, :out)
    assert [] = Router.lookup(net, :missing, :nope)
  end

  test "dispatch sends to a registered sink subscriber on the source port", %{net: net} do
    :ok = Router.register(net, [])
    :ok = Router.register_sink(net, :n1, :emitted, self())

    Router.dispatch(net, :n1, :emitted, %{value: 42})

    assert_receive {:bloccs_sink, ^net, :n1, :emitted, %{value: 42}}, 500
  end

  test "dispatch pushes to downstream producers", %{net: net} do
    {:ok, pid} = Producer.start_link(name: Router.producer_name(net, :downstream, :in))
    :ok = Router.register(net, [{{:upstream, :out}, [{:downstream, :in}]}])

    Router.dispatch(net, :upstream, :out, %{ping: 1})

    inner_state = :sys.get_state(pid).state
    assert :queue.len(inner_state.queue) == 1
    GenStage.stop(pid)
  end

  test "dispatch is a no-op for a source port with no targets and no sink", %{net: net} do
    :ok = Router.register(net, [])
    assert :ok = Router.dispatch(net, :nowhere, :emitted, %{value: 1})
  end

  test "producer_name and pipeline_name are stable across calls", %{net: net} do
    assert Router.producer_name(net, :n, :p) == Router.producer_name(net, :n, :p)
    assert Router.pipeline_name(net, :n) == Router.pipeline_name(net, :n)
    refute Router.producer_name(net, :n, :p) == Router.pipeline_name(net, :n)
  end
end
