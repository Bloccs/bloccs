defmodule Bloccs.RuntimeTest do
  @moduledoc """
  Unit coverage for `Bloccs.Runtime.process/2` — the execution core the
  generated Broadway pipelines delegate to. Exercises the contract
  (`pure_core` → `effect_shell` → emit) directly, without booting a full
  network, by pointing a hand-built `Config` at an inline impl module.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Parser, Runtime, Schema}
  alias Broadway.Message

  defmodule Impl do
    @moduledoc false

    # Pure core: classify the payload. Honors a `:raise` flag to exercise rescue.
    def transform(%{"raise" => true}, _ctx), do: raise("boom in pure_core")
    def transform(%{"bad" => true}, _ctx), do: {:error, :rejected_by_pure}

    def transform(%{"sleep_ms" => ms} = data, _ctx) when is_integer(ms) do
      Process.sleep(ms)
      {:ok, data}
    end

    def transform(data, _ctx), do: {:ok, data}

    # Effect shell: emit on the named port, or fail / route by content.
    def execute(%{"shell_error" => true}, _ctx), do: {:error, :rejected_by_shell}
    def execute(data, _ctx), do: {:emit, :out, data}
  end

  @manifest ~S"""
  [node]
  id = "runtime_demo"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  inbound = { schema = "RtReq@1" }

  [ports.out]
  out = { schema = "RtResp@1" }

  [effects]

  [contract]
  pure_core = "Bloccs.RuntimeTest.Impl.transform/2"
  effect_shell = "Bloccs.RuntimeTest.Impl.execute/2"
  """

  setup do
    Schema.clear!()
    on_exit(fn -> Schema.clear!() end)
    Application.put_env(:bloccs, :validate_inbound, true)
    Application.delete_env(:bloccs, :require_schemas)

    {:ok, manifest} = Parser.parse_node_string(@manifest)

    cfg = %Runtime.Config{
      manifest: manifest,
      network_id: :rt_net,
      local_id: :demo,
      in_port: :inbound
    }

    # Subscribe as the sink for the source port so we observe emits.
    Bloccs.Router.register(:rt_net, [])
    Bloccs.Router.register_sink(:rt_net, :demo, :out, self())

    %{cfg: cfg}
  end

  @timeout_manifest ~S"""
  [node]
  id = "runtime_timeout_demo"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  inbound = { schema = "RtReq@1" }

  [ports.out]
  out = { schema = "RtResp@1" }

  [effects]

  [contract]
  pure_core = "Bloccs.RuntimeTest.Impl.transform/2"
  effect_shell = "Bloccs.RuntimeTest.Impl.execute/2"
  timeout_ms = 50
  """

  @retry_manifest ~S"""
  [node]
  id = "runtime_retry_demo"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  inbound = { schema = "RtReq@1" }

  [ports.out]
  out = { schema = "RtResp@1" }

  [effects]

  [contract]
  pure_core = "Bloccs.RuntimeTest.Impl.transform/2"
  effect_shell = "Bloccs.RuntimeTest.Impl.execute/2"
  retry = { strategy = "constant", max = 2, on = [], base_ms = 5 }
  """

  @idempotent_manifest ~S"""
  [node]
  id = "runtime_idem_demo"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  inbound = { schema = "RtReq@1" }

  [ports.out]
  out = { schema = "RtResp@1" }

  [effects]

  [contract]
  pure_core = "Bloccs.RuntimeTest.Impl.transform/2"
  effect_shell = "Bloccs.RuntimeTest.Impl.execute/2"
  idempotency = { key = "request_id" }
  """

  # A minimal GenStage consumer that forwards every delivered message to a
  # test pid — lets us observe what a producer emits without poking internals.
  defmodule Collector do
    @moduledoc false
    use GenStage

    def start_link(producer, owner), do: GenStage.start_link(__MODULE__, {producer, owner})

    @impl true
    def init({producer, owner}),
      do: {:consumer, owner, subscribe_to: [{producer, max_demand: 10}]}

    @impl true
    def handle_events(events, _from, owner) do
      Enum.each(events, &send(owner, {:consumed, &1}))
      {:noreply, [], owner}
    end
  end

  defp msg(data, meta \\ %{}),
    do: %Message{data: data, metadata: meta, acknowledger: {Bloccs.Producer.Acknowledger, :x, :x}}

  defp refute_failed(%Message{} = msg), do: not match?(%Message{status: {:failed, _}}, msg)

  describe "process/2 happy path" do
    test "runs pure_core → effect_shell → dispatch and returns an un-failed message", %{cfg: cfg} do
      result = Runtime.process(msg(%{"k" => "v"}), cfg)

      refute match?(%Message{status: {:failed, _}}, result)
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"k" => "v"}}
    end
  end

  describe "process/2 failure paths" do
    test "fails the message when pure_core returns {:error, _}", %{cfg: cfg} do
      assert %Message{status: {:failed, :rejected_by_pure}} =
               Runtime.process(msg(%{"bad" => true}), cfg)

      refute_receive {:bloccs_sink, _, _, _, _}
    end

    test "fails the message when effect_shell returns {:error, _}", %{cfg: cfg} do
      assert %Message{status: {:failed, :rejected_by_shell}} =
               Runtime.process(msg(%{"shell_error" => true}), cfg)

      refute_receive {:bloccs_sink, _, _, _, _}
    end

    test "rescues exceptions raised in the node and fails the message", %{cfg: cfg} do
      assert %Message{status: {:failed, %RuntimeError{}}} =
               Runtime.process(msg(%{"raise" => true}), cfg)
    end
  end

  describe "process/2 timeout_ms" do
    setup %{cfg: cfg} do
      {:ok, manifest} = Parser.parse_node_string(@timeout_manifest)
      %{tcfg: %{cfg | manifest: manifest}}
    end

    test "fails with :timeout when the node exceeds timeout_ms", %{tcfg: tcfg} do
      assert %Message{status: {:failed, :timeout}} =
               Runtime.process(msg(%{"sleep_ms" => 500}), tcfg)

      refute_receive {:bloccs_sink, _, _, _, _}, 200
    end

    test "completes normally when the node finishes within timeout_ms", %{tcfg: tcfg} do
      result = Runtime.process(msg(%{"sleep_ms" => 1}), tcfg)

      refute match?(%Message{status: {:failed, _}}, result)
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"sleep_ms" => 1}}
    end
  end

  describe "process/2 retry" do
    setup %{cfg: cfg} do
      {:ok, manifest} = Parser.parse_node_string(@retry_manifest)
      rcfg = %{cfg | manifest: manifest}

      # Stand up the node's own producer (+ a consumer) so scheduled retries
      # land somewhere observable.
      producer_name = Bloccs.Router.producer_name(:rt_net, :demo, :inbound)
      {:ok, prod} = Bloccs.Producer.start_link(name: producer_name)
      {:ok, cons} = Collector.start_link(prod, self())

      on_exit(fn ->
        if Process.alive?(cons), do: GenStage.stop(cons)
        if Process.alive?(prod), do: GenStage.stop(prod)
      end)

      %{rcfg: rcfg}
    end

    test "re-enqueues a retriable failure with an incremented attempt count and acks the delivery",
         %{rcfg: rcfg} do
      # attempt 0, fails with {:error, :rejected_by_pure} → retriable (on: [])
      result = Runtime.process(msg(%{"bad" => true}), rcfg)

      # Current delivery is acked (not failed) because a retry now owns the work.
      refute match?(%Message{status: {:failed, _}}, result)

      assert_receive {:consumed,
                      %Message{data: %{"bad" => true}, metadata: %{bloccs_attempt: 1}}},
                     500
    end

    test "fails (no retry) once the attempt count reaches max", %{rcfg: rcfg} do
      # Arrive already at attempt 2 == max → no retry, hard fail.
      result = Runtime.process(msg(%{"bad" => true}, %{bloccs_attempt: 2}), rcfg)

      assert %Message{status: {:failed, :rejected_by_pure}} = result
      refute_receive {:consumed, _}, 100
    end

    test "permanent failures (schema mismatch) are not retried even with a policy", %{rcfg: rcfg} do
      Schema.register("RtReq@1", k: :string)

      result = Runtime.process(msg(%{"k" => 123}), rcfg)

      assert %Message{status: {:failed, {:schema_mismatch, "RtReq@1", _}}} = result
      refute_receive {:consumed, _}, 100
    end
  end

  describe "process/2 idempotency" do
    setup %{cfg: cfg} do
      Bloccs.Idempotency.reset()
      on_exit(&Bloccs.Idempotency.reset/0)
      {:ok, manifest} = Parser.parse_node_string(@idempotent_manifest)
      %{icfg: %{cfg | manifest: manifest}}
    end

    test "first delivery of a key runs and emits; a later duplicate is skipped", %{icfg: icfg} do
      assert refute_failed(Runtime.process(msg(%{"request_id" => "r1", "n" => 1}), icfg))
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"request_id" => "r1"}}

      # Same key, fresh delivery → acked but NOT re-run (no second emit).
      assert refute_failed(Runtime.process(msg(%{"request_id" => "r1", "n" => 2}), icfg))
      refute_receive {:bloccs_sink, _, _, _, _}, 100
    end

    test "distinct keys both run", %{icfg: icfg} do
      Runtime.process(msg(%{"request_id" => "r1"}), icfg)
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"request_id" => "r1"}}

      Runtime.process(msg(%{"request_id" => "r2"}), icfg)
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"request_id" => "r2"}}
    end

    test "concurrent first-deliveries of one key: exactly one runs (in-flight reservation)",
         %{icfg: icfg} do
      # Each delivery sleeps, so every reservation is attempted while the winner
      # is still in-flight (not yet marked done) — this proves in-flight dedup,
      # not merely completed-key dedup.
      payload = %{"request_id" => "concurrent-1", "sleep_ms" => 80}

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Runtime.process(msg(payload), icfg) end) end)
        |> Task.await_many(2_000)

      # Exactly one emit reaches the sink.
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"request_id" => "concurrent-1"}}, 500
      refute_receive {:bloccs_sink, :rt_net, :demo, :out, _}, 150

      # One ran, four were skipped — none failed.
      assert Enum.all?(results, &(not match?(%Message{status: {:failed, _}}, &1)))
    end

    test "a failed first delivery does not mark the key (so it can be reprocessed)", %{icfg: icfg} do
      # `bad` makes pure_core fail; key must NOT be marked.
      assert %Message{status: {:failed, _}} =
               Runtime.process(msg(%{"request_id" => "r1", "bad" => true}), icfg)

      refute Bloccs.Idempotency.seen?({:rt_net, :demo}, "r1")

      # A clean redelivery of the same key now succeeds.
      assert refute_failed(Runtime.process(msg(%{"request_id" => "r1"}), icfg))
      assert_receive {:bloccs_sink, :rt_net, :demo, :out, %{"request_id" => "r1"}}
    end
  end

  describe "process/2 telemetry" do
    setup do
      ref = make_ref()
      handler = "rt-tel-#{inspect(ref)}"

      events = [
        [:bloccs, :node, :start],
        [:bloccs, :node, :stop],
        [:bloccs, :node, :retry],
        [:bloccs, :node, :skipped]
      ]

      test_pid = self()

      :telemetry.attach_many(
        handler,
        events,
        fn event, meas, meta, _ -> send(test_pid, {:telemetry, event, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "emits span start + stop with outcome :ok on success", %{cfg: cfg} do
      Runtime.process(msg(%{"k" => "v"}), cfg)

      assert_receive {:telemetry, [:bloccs, :node, :start], %{system_time: _},
                      %{network: :rt_net, node: :demo, in_port: :inbound, attempt: 0}}

      assert_receive {:telemetry, [:bloccs, :node, :stop], %{duration: _}, %{outcome: :ok}}
    end

    test "stop carries outcome :failed and the reason on failure", %{cfg: cfg} do
      Runtime.process(msg(%{"bad" => true}), cfg)

      assert_receive {:telemetry, [:bloccs, :node, :stop], _meas,
                      %{outcome: :failed, reason: :rejected_by_pure}}
    end

    test "emits a :retry event when a retry is scheduled", %{cfg: cfg} do
      {:ok, manifest} = Parser.parse_node_string(@retry_manifest)
      rcfg = %{cfg | manifest: manifest}

      Runtime.process(msg(%{"bad" => true}), rcfg)

      assert_receive {:telemetry, [:bloccs, :node, :retry], %{delay_ms: _, next_attempt: 1},
                      %{reason: :rejected_by_pure}}
    end

    test "emits a :skipped event when a duplicate is dropped", %{cfg: cfg} do
      Bloccs.Idempotency.reset()
      on_exit(&Bloccs.Idempotency.reset/0)
      {:ok, manifest} = Parser.parse_node_string(@idempotent_manifest)
      icfg = %{cfg | manifest: manifest}

      Runtime.process(msg(%{"request_id" => "dup1"}), icfg)
      Runtime.process(msg(%{"request_id" => "dup1"}), icfg)

      assert_receive {:telemetry, [:bloccs, :node, :skipped], %{}, %{node: :demo}}
    end
  end

  describe "process/2 inbound validation" do
    test "rejects payloads that don't match the port schema before running the node", %{cfg: cfg} do
      Schema.register("RtReq@1", k: :string)

      assert %Message{status: {:failed, {:schema_mismatch, "RtReq@1", _}}} =
               Runtime.process(msg(%{"k" => 123}), cfg)

      refute_receive {:bloccs_sink, _, _, _, _}
    end
  end
end
