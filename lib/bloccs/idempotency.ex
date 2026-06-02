defmodule Bloccs.Idempotency do
  @moduledoc """
  Tracks which idempotency keys a node has already processed, so a node
  declaring `[contract].idempotency = { key = "request_id" }` drops duplicate
  deliveries instead of re-running its effects.

  ## Semantics (v0.4)

  A key is **reserved on entry** via an atomic `:ets.insert_new`, so two
  simultaneous first-deliveries of the same key cannot both proceed — exactly
  one wins the reservation and runs; the other is treated as a duplicate. On
  successful completion the entry is kept (and its TTL refreshed); on terminal
  failure it is **released**, so a genuinely new submission can be reprocessed.
  Retries bypass reservation (they already own the key from the first attempt).

  Entries expire after `config :bloccs, :idempotency_ttl_ms` (default 1 hour) and
  are swept periodically — this also frees reservations abandoned by a crashed
  process. The backing ETS table is public with read+write concurrency.
  """

  use GenServer

  @table :bloccs_idempotency
  @default_ttl_ms 3_600_000
  @sweep_interval_ms 60_000

  @type scope :: {atom(), atom()}

  @doc "Start the tracker. Started by `Bloccs.Application`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Has `key` already been reserved or completed for `scope` (within the TTL
  window)? Safe to call before the tracker has started — returns `false`.
  """
  @spec seen?(scope(), term()) :: boolean()
  def seen?(scope, key) do
    case :ets.whereis(@table) do
      :undefined -> false
      _ -> :ets.member(@table, {scope, key})
    end
  end

  @doc """
  Atomically reserve `key` for `scope`. Returns `true` if the caller now owns
  the key (proceed), or `false` if it was already reserved/completed (treat as a
  duplicate). Fail-open: returns `true` if the tracker hasn't started.
  """
  @spec reserve(scope(), term()) :: boolean()
  def reserve(scope, key) do
    case :ets.whereis(@table) do
      :undefined -> true
      _ -> :ets.insert_new(@table, {{scope, key}, now_ms()})
    end
  end

  @doc """
  Release a previously reserved `key` (on terminal failure), so a fresh
  submission can be reprocessed. No-op if the tracker hasn't started.
  """
  @spec release(scope(), term()) :: :ok
  def release(scope, key) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.delete(@table, {scope, key})
        :ok
    end
  end

  @doc """
  Mark `key` as processed for `scope`. No-op if the tracker hasn't started.
  """
  @spec mark(scope(), term()) :: :ok
  def mark(scope, key) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.insert(@table, {{scope, key}, now_ms()})
        :ok
    end
  end

  @doc false
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: Application.get_env(:bloccs, :idempotency_ttl_ms, @default_ttl_ms)

  @doc "Drop all tracked keys. Test-only."
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  # ---------------- GenServer ----------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - ttl_ms()
    # match_delete every entry whose stored timestamp is older than the cutoff
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
