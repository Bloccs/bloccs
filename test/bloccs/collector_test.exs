defmodule Bloccs.CollectorTest do
  # The collector is a singleton with global state — keep these serial.
  use ExUnit.Case, async: false

  alias Bloccs.Collector

  test "register/3 with timeout :infinity does not kill the collector" do
    pid = Process.whereis(Collector)
    assert is_pid(pid)

    # Before the fix this raised ArgumentError inside handle_call
    # (Process.send_after rejects :infinity), killing the singleton and
    # every in-flight request with it.
    assert :ok = Collector.register(:collector_test_net, "trace-inf", :infinity)
    assert Process.alive?(pid)
    assert Process.whereis(Collector) == pid

    # The slot is live and still completes a normal round-trip.
    task = Task.async(fn -> Collector.await(:collector_test_net, "trace-inf") end)
    Collector.report(:collector_test_net, "trace-inf", %{"answer" => 42})
    assert {:ok, %{"answer" => 42}} = Task.await(task)
  end

  test "register_async/4 with timeout :infinity delivers the reply" do
    assert :ok = Collector.register_async(:collector_test_net, "trace-inf-2", self(), :infinity)
    Collector.report(:collector_test_net, "trace-inf-2", %{"ok" => true})
    assert_receive {:bloccs_reply, "trace-inf-2", {:ok, %{"ok" => true}}}
  end
end
