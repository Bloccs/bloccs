defmodule Bloccs.TelemetryTest do
  @moduledoc "Coverage for the default logger handler attach/detach lifecycle."

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Bloccs.Telemetry

  setup do
    on_exit(&Telemetry.detach_default_logger/0)
    :ok
  end

  test "attach is idempotent and detach removes the handler" do
    assert :ok = Telemetry.attach_default_logger()
    assert {:error, :already_exists} = Telemetry.attach_default_logger()
    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end

  test "default handler logs node stop events" do
    :ok = Telemetry.attach_default_logger(:info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:bloccs, :node, :stop],
          %{duration: System.convert_time_unit(3, :millisecond, :native)},
          %{network: :n, node: :node_a, outcome: :ok}
        )
      end)

    assert log =~ "bloccs n.node_a ok"
  end

  test "default handler logs producer back-pressure" do
    :ok = Telemetry.attach_default_logger(:info)

    log =
      capture_log(fn ->
        :telemetry.execute([:bloccs, :producer, :backpressure], %{size: 10}, %{
          name: :p,
          buffer: 10
        })
      end)

    assert log =~ "back-pressure"
  end
end
