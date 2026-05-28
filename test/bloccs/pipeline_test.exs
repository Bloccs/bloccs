defmodule Bloccs.PipelineTest do
  @moduledoc """
  Unit coverage for `Bloccs.Pipeline.validate_inbound/3`. The integration
  test under `test/integration/` exercises the same path via the live
  compiled pipeline.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Parser, Pipeline, Schema}

  @manifest ~S"""
  [node]
  id = "validator_demo"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  inbound = { schema = "ValidatorReq@1" }

  [ports.out]
  outbound = { schema = "ValidatorResp@1" }

  [effects]

  [contract]
  pure_core = "Bloccs.Stub.transform/2"
  effect_shell = "Bloccs.Stub.execute/2"
  """

  setup do
    Schema.clear!()
    on_exit(fn -> Schema.clear!() end)

    Application.put_env(:bloccs, :validate_inbound, true)
    Application.delete_env(:bloccs, :require_schemas)

    {:ok, manifest} = Parser.parse_node_string(@manifest)
    %{manifest: manifest}
  end

  describe "validate_inbound/3" do
    test "passes well-formed payloads against a registered schema", %{manifest: m} do
      Schema.register("ValidatorReq@1", id: :string, n: :integer)

      assert :ok = Pipeline.validate_inbound(m, :inbound, %{id: "x", n: 1})
      assert :ok = Pipeline.validate_inbound(m, :inbound, %{"id" => "x", "n" => 1})
    end

    test "fails with structured reasons when fields are missing", %{manifest: m} do
      Schema.register("ValidatorReq@1", id: :string, n: :integer)

      assert {:error, {:schema_mismatch, "ValidatorReq@1", reasons}} =
               Pipeline.validate_inbound(m, :inbound, %{id: "x"})

      assert Enum.any?(reasons, &(&1 =~ "missing field n"))
    end

    test "fails on type mismatches", %{manifest: m} do
      Schema.register("ValidatorReq@1", id: :string, n: :integer)

      assert {:error, {:schema_mismatch, "ValidatorReq@1", reasons}} =
               Pipeline.validate_inbound(m, :inbound, %{id: "x", n: "not an int"})

      assert Enum.any?(reasons, &(&1 =~ "n"))
    end

    test "fails when payload is not a map", %{manifest: m} do
      Schema.register("ValidatorReq@1", id: :string)

      assert {:error, {:payload_not_map, "raw string"}} =
               Pipeline.validate_inbound(m, :inbound, "raw string")
    end

    test "fails on unknown port", %{manifest: m} do
      assert {:error, {:unknown_port, :nope}} =
               Pipeline.validate_inbound(m, :nope, %{})
    end
  end

  describe "validate_inbound/3 — soft-fail on unregistered schemas (default)" do
    test "returns :ok when the declared schema isn't registered", %{manifest: m} do
      # ValidatorReq@1 not registered in this test.
      assert :ok = Pipeline.validate_inbound(m, :inbound, %{anything: "goes"})
    end

    test "with :require_schemas enabled, missing registration is fatal", %{manifest: m} do
      Application.put_env(:bloccs, :require_schemas, true)

      assert {:error, {:schema_mismatch, "ValidatorReq@1", reasons}} =
               Pipeline.validate_inbound(m, :inbound, %{anything: "goes"})

      assert "schema not registered" in reasons
    end
  end

  describe "validate_inbound/3 — global toggle" do
    test "with :validate_inbound disabled, always returns :ok", %{manifest: m} do
      Application.put_env(:bloccs, :validate_inbound, false)
      Schema.register("ValidatorReq@1", id: :string, n: :integer)

      # Would normally fail (missing :n) — but validation is off.
      assert :ok = Pipeline.validate_inbound(m, :inbound, %{id: "x"})
    end
  end
end
