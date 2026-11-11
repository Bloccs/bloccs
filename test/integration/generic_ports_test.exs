defmodule Bloccs.Integration.GenericPortsTest do
  @moduledoc "Prototype for bounded generic ports (Bloccs/bloccs#48, VEN-76)."
  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Generics, Parser, Producer, Router, Validator}
  alias Bloccs.Integration.GenericPortsFixtures.Audit

  @fixtures "test/fixtures/generic_ports"

  defp parse(name), do: Parser.parse_network(Path.join(@fixtures, name))

  defp parse_error(name) do
    assert {:error, [issue]} = parse(name)
    issue.message
  end

  describe "wiring" do
    test "one module is bound to a different schema per use" do
      assert {:ok, network} = parse("gp_two_uses.bloccs")
      assert :ok = Validator.validate_network(network)

      for {id, schema} <- [audit_o: "GpOrder@1", audit_i: "GpInvoice@1"] do
        manifest = network.nodes[id].manifest
        assert manifest.contract.pure_core.module == Audit
        assert manifest.ports_in[:in].schema == schema
        assert manifest.ports_out[:out].schema == schema
      end
    end

    test "a generic node fed by another generic node resolves" do
      assert {:ok, network} = parse("gp_chained.bloccs")
      assert :ok = Validator.validate_network(network)
      assert network.nodes[:stamp].manifest.ports_out[:out].schema == "GpOrder@1"
    end

    test "a producer without the required field is rejected" do
      assert parse_error("gp_missing_field.bloccs") =~
               "GpAnon@1 does not satisfy GpKeyed@1 (missing field id)"
    end

    test "a producer with the wrong field type is rejected" do
      assert parse_error("gp_wrong_type.bloccs") =~ "field id is :integer, needs :string"
    end

    test "the bound schema is checked against the consumer after the utility" do
      assert {:ok, network} = parse("gp_wrong_consumer.bloccs")
      assert {:error, issues} = Validator.validate_network(network)

      assert Enum.any?(
               issues,
               &(&1.message =~ "audit.out=GpInvoice@1 but order_sink.in=GpOrder@1")
             )
    end

    test "undeclared shapes fail closed" do
      assert parse_error("gp_no_shapes.bloccs") =~ "the shape of GpUndeclared@1 is not declared"
    end

    test "the embedded-manifest check accepts a bound generic node" do
      assert {:ok, network} = parse("gp_two_uses.bloccs")
      assert :ok = Compiler.check_embedded_manifests(network)
    end
  end

  describe "runtime" do
    setup do
      {:ok, network} = parse("gp_two_uses.bloccs")
      Generics.register_schemas(network)
      {:ok, sup} = Compiler.compile_and_load(network)
      start_supervised!(sup)

      test_pid = self()
      handler = "generic-ports-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:bloccs, :node, :stop],
        fn _event, _measurements, meta, _config ->
          if meta[:outcome] == :failed, do: send(test_pid, {:failed, meta[:node], meta[:reason]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Router.register_sink(:gp_two_uses, :order_sink, :done, self())
      Router.register_sink(:gp_two_uses, :invoice_sink, :done, self())
      :ok
    end

    defp push(source, payload),
      do: Producer.push(Router.producer_name(:gp_two_uses, source, :raw), payload)

    test "each use delivers the producer's full payload" do
      push(:order_source, %{id: "o-1", total: 4900})
      assert_receive {:bloccs_sink, _, :order_sink, _, data}, 2000
      assert data == %{id: "o-1", total: 4900, audited: "audit:o-1"}

      push(:invoice_source, %{id: "i-1", total: 100, due: "2026-12-01"})
      assert_receive {:bloccs_sink, _, :invoice_sink, _, data}, 2000
      assert data == %{id: "i-1", total: 100, due: "2026-12-01", audited: "audit:i-1"}
    end

    test "each use rejects at its own inlet against its bound schema" do
      push(:order_source, %{id: "o-2", total: "49.00"})
      assert_receive {:failed, :audit_o, {:schema_mismatch, "GpOrder@1", _}}, 2000

      push(:invoice_source, %{id: "i-2", total: 100})

      assert_receive {:failed, :audit_i,
                      {:schema_mismatch, "GpInvoice@1", ["missing field due"]}},
                     2000
    end
  end
end
