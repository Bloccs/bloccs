defmodule Bloccs.Effects.DB.Mock do
  @moduledoc """
  Mock DB backend. Refuses out-of-scope table actions. Records every
  successful insert for test introspection via `inserts/0`, and serves reads
  (`get/3` / `all/3` / `one/3`) from that same in-memory log.

  Test/dev backend (the default). Its store is an Agent started lazily on
  first use and is NOT supervised — fine for tests, not a production process.
  Use `Bloccs.Effects.DB.Ecto` in production.

  Reads return rows as **string-keyed maps** (the same contract as `DB.Ecto`),
  even though inserts may use atom keys — so a node's read logic is
  backend-agnostic.
  """

  alias Bloccs.Effects

  @behaviour Bloccs.Effects.DB

  defstruct allow: []

  @impl true
  def new(%{allow: allow}), do: %__MODULE__{allow: allow}

  @impl true
  @spec insert(%__MODULE__{}, atom() | String.t(), keyword() | map()) ::
          {:ok, map()} | no_return()
  def insert(%__MODULE__{allow: allow}, table, attrs) do
    scope = "#{table}:insert"

    if scope in allow do
      attrs = Map.new(List.wrap(attrs))
      row = Map.put(attrs, :id, :erlang.unique_integer([:positive, :monotonic]))
      record_insert(table, row)
      {:ok, row}
    else
      Effects.deny!(:db, "scope #{scope} not in #{inspect(allow)}")
    end
  end

  @impl true
  def get(%__MODULE__{} = cap, table, id), do: one(cap, table, %{"id" => id})

  @impl true
  def all(%__MODULE__{allow: allow}, table, filter) do
    with_read(allow, table, fn -> {:ok, rows_matching(table, filter)} end)
  end

  @impl true
  def one(%__MODULE__{allow: allow}, table, filter) do
    with_read(allow, table, fn ->
      case rows_matching(table, filter) do
        [] -> {:ok, nil}
        [row] -> {:ok, row}
        _ -> {:error, :multiple_results}
      end
    end)
  end

  defp with_read(allow, table, fun) do
    scope = "#{table}:read"

    if scope in allow,
      do: fun.(),
      else: Effects.deny!(:db, "scope #{scope} not in #{inspect(allow)}")
  end

  # Rows for `table` in insertion order, string-keyed, filtered by ANDed equality.
  defp rows_matching(table, filter) do
    inserts()
    |> Enum.reverse()
    |> Enum.filter(fn {t, _row} -> to_string(t) == to_string(table) end)
    |> Enum.map(fn {_t, row} -> stringify(row) end)
    |> Enum.filter(&matches?(&1, filter))
  end

  defp matches?(_row, filter) when map_size(filter) == 0, do: true

  defp matches?(row, filter) do
    Enum.all?(filter, fn {k, v} -> Map.get(row, to_string(k)) == v end)
  end

  defp stringify(row), do: Map.new(row, fn {k, v} -> {to_string(k), v} end)

  @spec inserts() :: [{atom() | String.t(), map()}]
  def inserts do
    Agent.get(ensure_pid(), & &1)
  end

  @spec reset() :: :ok
  def reset, do: Agent.update(ensure_pid(), fn _ -> [] end)

  defp record_insert(table, row) do
    Agent.update(ensure_pid(), &[{table, row} | &1])
  end

  defp ensure_pid do
    case Process.whereis(__MODULE__) do
      nil -> start_log()
      pid -> pid
    end
  end

  # Started UNLINKED so the insert log survives the VM, not the first caller.
  # `start_link` would tie the agent's life to whatever (test) process first
  # touched it; it would then die on that process's exit and a later caller would
  # race onto a dead name. `start` (+ already-started handling) avoids that.
  defp start_log do
    case Agent.start(fn -> [] end, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
