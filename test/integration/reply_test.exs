defmodule Bloccs.Integration.ReplyTest do
  @moduledoc """
  End-to-end proof of request/response: `Bloccs.call/4` pushes a request into a
  running network and blocks for the reply emitted by a `reply = true` node,
  correlated by the message's trace_id (`Bloccs.Collector`). `cast/4` is the
  async variant. The pipeline itself stays asynchronous — only the caller waits.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Schema, Validator}

  @path Path.expand("../fixtures/reply/reply.bloccs", __DIR__)

  setup_all do
    Schema.clear!()
    Schema.register("Req@1", n: :integer)
    Schema.register("Res@1", total: :integer)

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

  test "call/4 blocks and returns the reply the reply-node computed" do
    assert {:ok, %{"total" => 10}} = Bloccs.call(:reply_demo, :request, %{"n" => 5})
  end

  test "call/4 resolves the entry through an exposed input port" do
    assert {:error, {:unknown_port, :nope}} = Bloccs.call(:reply_demo, :nope, %{"n" => 1})
  end

  test "call/4 returns {:error, :unknown_network} for a network that isn't running" do
    assert {:error, :unknown_network} = Bloccs.call(:no_such_network, :request, %{"n" => 1})
  end

  test "call/4 returns a typed {:error, %EffectError{}} on an inbound-schema failure" do
    # A bad payload fails Req@1 at the ingest node; the error comes back as data
    # rather than as a timeout.
    assert {:error, %Bloccs.EffectError{phase: :validate, node: :ingest}} =
             Bloccs.call(:reply_demo, :request, %{"n" => "not-an-int"})
  end

  test "call/4 returns a typed {:error, %EffectError{}} when the reply node raises" do
    assert {:error, %Bloccs.EffectError{phase: :execute, node: :price}} =
             Bloccs.call(:reply_demo, :request, %{"n" => 0})
  end

  test "call/4 returns {:error, :timeout} when the request is dropped (no reply, no error)" do
    # A negative total is filtered at the reply node: nothing is emitted and
    # nothing fails, so the caller times out cleanly instead of hanging.
    assert {:error, :timeout} =
             Bloccs.call(:reply_demo, :request, %{"n" => -3}, timeout: 200)
  end

  test "cast/4 returns a trace_id and delivers the reply asynchronously" do
    {:ok, trace_id} = Bloccs.cast(:reply_demo, :request, %{"n" => 7}, send_result: true)
    assert is_integer(trace_id)
    assert_receive {:bloccs_reply, ^trace_id, {:ok, %{"total" => 14}}}, 1_000
  end

  test "cast/4 delivers a typed error asynchronously" do
    {:ok, trace_id} = Bloccs.cast(:reply_demo, :request, %{"n" => 0}, send_result: true)

    assert_receive {:bloccs_reply, ^trace_id, {:error, %Bloccs.EffectError{phase: :execute}}},
                   1_000
  end

  test "cast/4 without send_result is fire-and-forget but still yields the trace_id" do
    assert {:ok, trace_id} = Bloccs.cast(:reply_demo, :request, %{"n" => 3})
    assert is_integer(trace_id)
    refute_receive {:bloccs_reply, ^trace_id, _}, 100
  end

  describe "observability" do
    setup do
      handler = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler,
        [[:bloccs, :request, :start], [:bloccs, :request, :stop]],
        fn event, meas, meta, %{pid: pid} -> send(pid, {:telemetry, event, meas, meta}) end,
        %{pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "a successful call emits request start + stop (outcome :reply), correlated by trace_id" do
      assert {:ok, %{"total" => 10}} = Bloccs.call(:reply_demo, :request, %{"n" => 5})

      assert_receive {:telemetry, [:bloccs, :request, :start], _meas,
                      %{network: :reply_demo, mode: :call, trace_id: t}}

      assert_receive {:telemetry, [:bloccs, :request, :stop], %{duration: _},
                      %{outcome: :reply, trace_id: ^t}}
    end

    test "a failed call emits stop with outcome :error and the EffectError" do
      assert {:error, %Bloccs.EffectError{}} = Bloccs.call(:reply_demo, :request, %{"n" => 0})

      assert_receive {:telemetry, [:bloccs, :request, :stop], _meas,
                      %{outcome: :error, error: %Bloccs.EffectError{phase: :execute}}}
    end

    test "a timed-out call emits stop with outcome :timeout" do
      assert {:error, :timeout} = Bloccs.call(:reply_demo, :request, %{"n" => -3}, timeout: 100)

      assert_receive {:telemetry, [:bloccs, :request, :stop], _meas, %{outcome: :timeout}}, 500
    end

    test "stats/0 reports the in-flight request count" do
      assert %{in_flight: in_flight, by_network: by_network} = Bloccs.Collector.stats()
      assert is_integer(in_flight) and in_flight >= 0
      assert is_map(by_network)
    end
  end
end
