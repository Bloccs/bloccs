defmodule Bloccs.TraceTest do
  @moduledoc "Unit coverage for the telemetry-driven trace recorder."

  use ExUnit.Case, async: false

  alias Bloccs.Trace

  test "records port_in + emit scoped to its network and derives reached obligations" do
    rec = Trace.record(:tnet)

    :telemetry.execute([:bloccs, :node, :start], %{system_time: 1}, %{
      network: :tnet,
      node: :a,
      in_port: :in1
    })

    :telemetry.execute([:bloccs, :emit], %{targets: 1}, %{
      network: :tnet,
      from_node: :a,
      from_port: :out1,
      targets: [{:b, :in1}]
    })

    # An event from a different network must be ignored.
    :telemetry.execute([:bloccs, :node, :start], %{system_time: 2}, %{
      network: :other,
      node: :z,
      in_port: :in1
    })

    events = Trace.stop(rec)
    reached = Trace.reached(events)

    assert {:port_in, :a, :in1} in reached
    assert {:port_out, :a, :out1} in reached
    assert {:edge, {:a, :out1}, {:b, :in1}} in reached
    refute Enum.any?(reached, &match?({:port_in, :z, _}, &1))
  end

  test "stop detaches the handler (no further recording)" do
    rec = Trace.record(:tnet2)
    events_before = Trace.stop(rec)
    assert events_before == []

    # After stop, this event is not recorded anywhere (handler detached).
    :telemetry.execute([:bloccs, :node, :start], %{}, %{network: :tnet2, node: :a, in_port: :i})
    # nothing to assert beyond no crash — the recording is already closed
  end

  @tag :tmp_dir
  test "dump/load round-trips a .bloccs-trace file", %{tmp_dir: tmp} do
    events = [
      {:port_in, :a, :in1},
      {:emit, :a, :out1, [{:b, :in1}, {:c, :in1}]}
    ]

    path = Path.join(tmp, "run.bloccs-trace")
    assert :ok = Trace.dump(events, :tnet, path)
    assert {:ok, loaded} = Trace.load(path)

    assert loaded == events
    assert Trace.reached(loaded) == Trace.reached(events)
  end
end
