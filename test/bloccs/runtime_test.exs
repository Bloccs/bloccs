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

  defp msg(data), do: %Message{data: data, acknowledger: {Bloccs.Producer.Acknowledger, :x, :x}}

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

  describe "process/2 inbound validation" do
    test "rejects payloads that don't match the port schema before running the node", %{cfg: cfg} do
      Schema.register("RtReq@1", k: :string)

      assert %Message{status: {:failed, {:schema_mismatch, "RtReq@1", _}}} =
               Runtime.process(msg(%{"k" => 123}), cfg)

      refute_receive {:bloccs_sink, _, _, _, _}
    end
  end
end
