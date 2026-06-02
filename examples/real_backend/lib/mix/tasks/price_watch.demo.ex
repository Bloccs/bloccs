defmodule Mix.Tasks.PriceWatch.Demo do
  @shortdoc "Run the price_watch bloccs network end-to-end against real HTTP + SQLite"

  @moduledoc """
      mix price_watch.demo

  Compiles and starts the `price_watch` network, pushes a few quote requests
  through it, and prints the rows that were persisted to SQLite. Everything is
  real: the fetch node makes HTTP requests over a socket to the local stub API
  (via `Bloccs.Effects.HTTP.Req`), and the record node writes to a SQLite file
  (via `Bloccs.Effects.DB.Ecto`). No external services.

  Demonstrates idempotency too: the third push reuses the first request_id, so
  it is deduped and only two rows are written.
  """

  use Mix.Task

  alias Bloccs.{Compiler, Parser, Producer, Router, Validator}

  @network "networks/price_watch.bloccs"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, network} = Parser.parse_network(@network)
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    Router.register_sink(:price_watch, :record, :recorded, self())

    info("network `price_watch` running — pushing quote requests\n")

    push(%{symbol: "USD", request_id: "req-1"})
    push(%{symbol: "BTC", request_id: "req-2"})
    # Duplicate request_id → idempotency should skip this one.
    push(%{symbol: "USD", request_id: "req-1"})

    collect_emits(2)

    print_rows()
  end

  defp push(payload) do
    producer = Router.producer_name(:price_watch, :fetch, :quote_requested)
    Producer.push(producer, payload)
    info("  → pushed #{payload.symbol} (#{payload.request_id})")
  end

  defp collect_emits(0), do: :ok

  defp collect_emits(n) do
    receive do
      {:bloccs_sink, :price_watch, :record, :recorded, %{id: id, symbol: s, price: p}} ->
        info("  ← recorded ##{id} #{s} = #{p}")
        collect_emits(n - 1)
    after
      3_000 -> :ok
    end
  end

  defp print_rows do
    %{rows: rows} =
      PriceWatch.Repo.query!(
        "SELECT id, request_id, symbol, price, recorded_at FROM quotes ORDER BY id"
      )

    info("\nquotes table (#{length(rows)} row#{if length(rows) == 1, do: "", else: "s"}):")
    info("  id | request_id | symbol | price | recorded_at")

    Enum.each(rows, fn [id, rid, symbol, price, at] ->
      info("  #{id}  | #{rid}      | #{symbol}    | #{price}   | #{at}")
    end)

    info("\n(3 requests pushed, #{length(rows)} rows written — the duplicate req-1 was deduped)")
  end

  defp info(msg), do: Mix.shell().info(msg)
end
