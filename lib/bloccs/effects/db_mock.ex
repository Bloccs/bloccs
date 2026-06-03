defmodule Bloccs.Effects.DB.Mock do
  @moduledoc """
  Mock DB backend. Refuses out-of-scope table actions. Records every
  successful insert for test introspection via `inserts/0`.

  Test/dev backend (the default). Its insert log is an Agent started lazily on
  first use and is NOT supervised — fine for tests, not a production process.
  Use `Bloccs.Effects.DB.Ecto` in production.
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
