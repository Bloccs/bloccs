defmodule Bloccs.Integration.PaymentsTest do
  @moduledoc """
  The headline v0.1 assertion: parse → validate → compile → run the payments
  sample network with mock HTTP/DB effects, and observe messages emerging at
  every exposed output port for both the success and failure paths.
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Parser, Validator, Compiler, Router, Producer}
  alias Bloccs.Effects.HTTP.Mock, as: MockHTTP
  alias Bloccs.Effects.DB.Mock, as: MockDB

  @network_path Path.join([
                  Path.expand("../../examples/payments/networks", __DIR__),
                  "payments.bloccs"
                ])

  setup_all do
    Bloccs.Schema.clear!()
    Payments.Schemas.register()

    {:ok, network} = Parser.parse_network(@network_path)
    :ok = Validator.validate_network(network)
    {:ok, sup_module} = Compiler.compile_and_load(network)
    {:ok, _} = sup_module.start_link([])

    on_exit(fn ->
      try do
        Supervisor.stop(sup_module, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{network: network, supervisor: sup_module}
  end

  setup do
    MockHTTP.reset()
    MockDB.reset()
    Bloccs.Idempotency.reset()
    :ok = subscribe_to_exposed_ports()
    :ok
  end

  test "success path: charge_completed fans out to notify_ok + ledger" do
    MockHTTP.stub("POST", "https://api.stripe.com/v1/charges", fn _req ->
      %{"id" => "ch_test_ok", "status" => "succeeded"}
    end)

    MockHTTP.stub("POST", "https://api.postmarkapp.com/email", fn _req ->
      %{"MessageID" => "msg_1"}
    end)

    push_to_intake(%{
      method: "POST",
      path: "/charges",
      body: %{
        "customer_id" => "cus_ok",
        "amount_cents" => 2500,
        "currency" => "USD",
        "request_id" => "req_ok"
      }
    })

    assert_receive {:bloccs_sink, :payments, :notify_ok, :delivered, sent}, 2_000
    assert sent.template == "charge_ok"
    assert sent.to == "cus_ok@example.com"

    assert_receive {:bloccs_sink, :payments, :ledger, :committed, recorded}, 2_000
    assert recorded.event_type == "charge_completed"
    assert recorded.payload.customer_id == "cus_ok"
    assert recorded.payload.stripe_id == "ch_test_ok"

    refute_receive {:bloccs_sink, :payments, :notify_fail, :delivered, _}, 200

    assert [_charges_row, _ledger_row] = Enum.sort_by(MockDB.inserts(), &elem(&1, 0))
  end

  test "malformed payload at the intake port is rejected by runtime schema validation" do
    # `HttpRequest@1` declares :method, :path, :body. Sending a string fails
    # validation; sending a map missing :body fails too. Neither should make
    # it past the ingest pipeline, so no downstream sink should fire.

    push_to_intake("definitely not a map")

    refute_receive {:bloccs_sink, :payments, :notify_ok, :delivered, _}, 200
    refute_receive {:bloccs_sink, :payments, :notify_fail, :delivered, _}, 200
    refute_receive {:bloccs_sink, :payments, :ledger, :committed, _}, 200

    # Missing fields: body is required by HttpRequest@1
    push_to_intake(%{method: "POST", path: "/charges"})

    refute_receive {:bloccs_sink, :payments, :notify_ok, :delivered, _}, 200
    refute_receive {:bloccs_sink, :payments, :notify_fail, :delivered, _}, 200
    refute_receive {:bloccs_sink, :payments, :ledger, :committed, _}, 200
  end

  test "failure path: stripe failure routes to notify_fail (and skips ledger)" do
    MockHTTP.stub("POST", "https://api.stripe.com/v1/charges", fn _req ->
      %{"id" => "ch_test_fail", "status" => "failed"}
    end)

    MockHTTP.stub("POST", "https://api.postmarkapp.com/email", fn _req ->
      %{"MessageID" => "msg_2"}
    end)

    push_to_intake(%{
      method: "POST",
      path: "/charges",
      body: %{
        "customer_id" => "cus_fail",
        "amount_cents" => 999,
        "currency" => "USD",
        "request_id" => "req_fail"
      }
    })

    assert_receive {:bloccs_sink, :payments, :notify_fail, :delivered, rejected}, 2_000
    assert rejected.template == "charge_fail"
    assert rejected.to == "cus_fail@example.com"

    refute_receive {:bloccs_sink, :payments, :notify_ok, :delivered, _}, 200
    refute_receive {:bloccs_sink, :payments, :ledger, :committed, _}, 200
  end

  test "idempotency: a duplicate request_id is charged only once" do
    MockHTTP.stub("POST", "https://api.stripe.com/v1/charges", fn _req ->
      %{"id" => "ch_dup", "status" => "succeeded"}
    end)

    MockHTTP.stub("POST", "https://api.postmarkapp.com/email", fn _req ->
      %{"MessageID" => "msg_dup"}
    end)

    req = %{
      method: "POST",
      path: "/charges",
      body: %{
        "customer_id" => "cus_dup",
        "amount_cents" => 500,
        "currency" => "USD",
        "request_id" => "req_dup"
      }
    }

    push_to_intake(req)
    # Drain BOTH fanout emits of the first charge (notify_ok + ledger) so the
    # key is marked and nothing is left in the mailbox before the duplicate.
    assert_receive {:bloccs_sink, :payments, :notify_ok, :delivered, _}, 2_000
    assert_receive {:bloccs_sink, :payments, :ledger, :committed, _}, 2_000

    push_to_intake(req)
    refute_receive {:bloccs_sink, :payments, :ledger, :committed, _}, 500
    refute_receive {:bloccs_sink, :payments, :notify_ok, :delivered, _}, 200
  end

  test "telemetry: the charge node emits a stop event with outcome :ok on success" do
    test_pid = self()
    handler = "payments-charge-stop"

    :telemetry.attach(
      handler,
      [:bloccs, :node, :stop],
      fn _e, meas, meta, _ ->
        if meta.node == :charge, do: send(test_pid, {:charge_stop, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    MockHTTP.stub("POST", "https://api.stripe.com/v1/charges", fn _req ->
      %{"id" => "ch_tel", "status" => "succeeded"}
    end)

    MockHTTP.stub("POST", "https://api.postmarkapp.com/email", fn _req ->
      %{"MessageID" => "msg_tel"}
    end)

    push_to_intake(%{
      method: "POST",
      path: "/charges",
      body: %{
        "customer_id" => "cus_tel",
        "amount_cents" => 700,
        "currency" => "USD",
        "request_id" => "req_tel"
      }
    })

    assert_receive {:charge_stop, %{duration: dur}, %{outcome: :ok, observability: obs}}, 2_000
    assert is_integer(dur)
    # The node's declared [observability] block rides along in the metadata.
    assert obs.metrics == ["duration_ms"]

    # The charge :stop event fires before downstream fanout completes; drain the
    # downstream emits so they don't bleed into the next test's sink.
    assert_receive {:bloccs_sink, :payments, :notify_ok, :delivered, _}, 2_000
    assert_receive {:bloccs_sink, :payments, :ledger, :committed, _}, 2_000
  end

  defp subscribe_to_exposed_ports do
    :ok = Router.register_sink(:payments, :notify_ok, :delivered, self())
    :ok = Router.register_sink(:payments, :notify_fail, :delivered, self())
    :ok = Router.register_sink(:payments, :ledger, :committed, self())
    :ok
  end

  defp push_to_intake(http_req) do
    producer = Router.producer_name(:payments, :ingest, :http_request)
    Producer.push(producer, http_req)
  end
end
