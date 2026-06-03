defmodule Bloccs.Telemetry do
  @moduledoc """
  Telemetry events emitted by the bloccs runtime, and an optional default
  logger handler.

  Attach your own handlers with `:telemetry.attach/4` (or `attach_many/4`) to
  feed metrics into `Telemetry.Metrics`, OpenTelemetry, StatsD, etc. A node's
  `[observability]` block is passed through verbatim in every event's metadata
  under `:observability`, so a handler can filter by the metrics/traces a node
  declared.

  ## Events

  Per-message node execution is wrapped in `:telemetry.span/3`, which emits:

  - `[:bloccs, :node, :start]`
    - measurements: `%{system_time, monotonic_time}`
    - metadata: `%{network, node, in_port, attempt, observability, telemetry_span_context}`
  - `[:bloccs, :node, :stop]`
    - measurements: `%{duration, monotonic_time}`
    - metadata: above **plus** `:outcome` (`:ok | :failed`) and, when failed,
      `:reason`
  - `[:bloccs, :node, :exception]` — only if execution raises (the runtime
    rescues node errors, so this fires only on a bug in the runtime itself)
    - measurements: `%{duration, monotonic_time}`
    - metadata: above plus `:kind`, `:reason`, `:stacktrace`

  Routing emits a per-dispatch event (the signal `Bloccs.Trace` records for
  coverage):

  - `[:bloccs, :emit]` — a node emitted on an out-port
    - measurements: `%{targets}` (number of downstream edges)
    - metadata: `%{network, from_node, from_port, targets}` where `targets` is a
      list of `{to_node, to_port}`

  Two additional point-in-time events:

  - `[:bloccs, :node, :retry]` — a backed-off retry was scheduled
    - measurements: `%{delay_ms, next_attempt}`
    - metadata: base metadata plus `:reason`
  - `[:bloccs, :node, :skipped]` — an idempotent duplicate was dropped
    - measurements: `%{}`
    - metadata: base metadata

  `:producer` back-pressure is reported separately by `Bloccs.Producer`:

  - `[:bloccs, :producer, :backpressure]` — a `push/3` had to park because the
    buffer was full (the caller waits until a consumer drains space)
    - measurements: `%{size}`
    - metadata: `%{name, buffer}`
  """

  require Logger

  @events [
    [:bloccs, :node, :stop],
    [:bloccs, :node, :exception],
    [:bloccs, :node, :retry],
    [:bloccs, :node, :skipped],
    [:bloccs, :producer, :backpressure]
  ]

  @handler_id "bloccs-default-logger"

  @doc """
  Attach a built-in handler that logs the interesting runtime events. Handy in
  development; in production you'll usually attach your own metrics handlers
  instead. Idempotent — re-attaching is a no-op.
  """
  @spec attach_default_logger(Logger.level()) :: :ok | {:error, :already_exists}
  def attach_default_logger(level \\ :debug) do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{level: level})
  end

  @doc "Detach the default logger handler."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@handler_id)

  @doc "List the events the default logger handler subscribes to."
  def events, do: @events

  @doc false
  def handle_event([:bloccs, :node, :stop], %{duration: dur}, meta, %{level: level}) do
    ms = System.convert_time_unit(dur, :native, :microsecond) / 1000

    Logger.log(
      level,
      "bloccs #{meta.network}.#{meta.node} #{meta.outcome} in #{Float.round(ms, 2)}ms" <>
        reason_suffix(meta)
    )
  end

  def handle_event([:bloccs, :node, :exception], _meas, meta, _config) do
    Logger.error("bloccs #{meta.network}.#{meta.node} raised: #{inspect(Map.get(meta, :reason))}")
  end

  def handle_event([:bloccs, :node, :retry], %{delay_ms: delay, next_attempt: n}, meta, %{
        level: level
      }) do
    Logger.log(
      level,
      "bloccs #{meta.network}.#{meta.node} retry ##{n} in #{delay}ms (#{inspect(meta.reason)})"
    )
  end

  def handle_event([:bloccs, :node, :skipped], _meas, meta, %{level: level}) do
    Logger.log(level, "bloccs #{meta.network}.#{meta.node} skipped duplicate (idempotent)")
  end

  def handle_event([:bloccs, :producer, :backpressure], %{size: size}, meta, %{level: level}) do
    Logger.log(
      level,
      "bloccs producer #{inspect(meta.name)} back-pressure: buffer full " <>
        "(#{meta.buffer}, size #{size}); caller parked until drained"
    )
  end

  defp reason_suffix(%{outcome: :failed, reason: reason}), do: " — #{inspect(reason)}"
  defp reason_suffix(_), do: ""
end
