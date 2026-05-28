defmodule Bloccs.Effects.DB.Mock do
  @moduledoc """
  Mock DB backend. Refuses out-of-scope table actions. Records every
  successful insert for test introspection via `inserts/0`.
  """

  alias Bloccs.Effects

  defstruct allow: []

  def new(%{allow: allow}), do: %__MODULE__{allow: allow}

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
      nil ->
        {:ok, pid} = Agent.start_link(fn -> [] end, name: __MODULE__)
        pid

      pid ->
        pid
    end
  end
end
