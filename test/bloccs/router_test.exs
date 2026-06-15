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

  test "dispatch returns :ok when every downstream push succeeds", %{net: net} do
    {:ok, pid} = Producer.start_link(name: Router.producer_name(net, :downstream, :in))
    :ok = Router.register(net, [{{:upstream, :out}, [{:downstream, :in}]}])

    assert :ok = Router.dispatch(net, :upstream, :out, %{ping: 1})
    GenStage.stop(pid)
  end

  test "dispatch reports an undelivered emit instead of dropping it", %{net: net} do
    # Edge points at a producer that was never started → push returns :no_producer.
    :ok = Router.register(net, [{{:upstream, :out}, [{:gone, :in}]}])

    :telemetry.attach(
      "rtr-dispatch-err-#{net}",
      [:bloccs, :dispatch, :error],
      fn _event, _meas, meta, %{pid: pid} -> send(pid, {:dispatch_error, meta}) end,
      %{pid: self()}
    )

    assert {:error, [{{:gone, :in}, :no_producer}]} =
             Router.dispatch(net, :upstream, :out, %{ping: 1})

    assert_receive {:dispatch_error, %{to_node: :gone, reason: :no_producer}}, 500
    :telemetry.detach("rtr-dispatch-err-#{net}")
  end

  test "producer_name and pipeline_name are stable across calls", %{net: net} do
    assert Router.producer_name(net, :n, :p) == Router.producer_name(net, :n, :p)
    assert Router.pipeline_name(net, :n) == Router.pipeline_name(net, :n)
    refute Router.producer_name(net, :n, :p) == Router.pipeline_name(net, :n)
  end

  test "edge tables survive a Router restart", %{net: net} do
    on_exit(fn -> Router.unregister(net) end)
    :ok = Router.register(net, [{{:a, :out}, [{:b, :in_b}]}])

    old = Process.whereis(Router)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 1_000

    # Wait for the supervisor to bring the singleton back.
    new =
      Enum.find_value(1..100, fn _ ->
        Process.sleep(10)

        case Process.whereis(Router) do
          pid when is_pid(pid) and pid != old -> pid
          _ -> nil
        end
      end)

    assert is_pid(new)
    # Before the persistent_term move this returned [] — every dispatch after
    # a Router restart acked successfully while reaching nothing.
    assert [{:b, :in_b}] = Router.lookup(net, :a, :out)
  end

  test "dispatch to a network with no registered edge table fails loudly", %{net: net} do
    assert {:error, [{{:src, :out}, :network_not_registered}]} =
             Router.dispatch(net, :src, :out, %{value: 1})
  end

  test "unregister removes the edge table", %{net: net} do
    :ok = Router.register(net, [{{:a, :out}, [{:b, :in_b}]}])
    assert [{:b, :in_b}] = Router.lookup(net, :a, :out)

    :ok = Router.unregister(net)
    assert [] = Router.lookup(net, :a, :out)
  end
end
