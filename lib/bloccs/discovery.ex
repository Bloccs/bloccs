defmodule Bloccs.Discovery do
  @moduledoc """
  Boot-time registration of running networks, so introspection tools can
  enumerate them in O(1) without scanning the supervision tree.

  Each compiled network supervisor calls `register/2` from its `init/1`. The
  entry lives in `Bloccs.NetworkRegistry` keyed by the network id and is owned by
  the supervisor process, so it is removed automatically when that supervisor
  stops or crashes — `list/0` never reports a dead network.

  > A network compiled with an older bloccs won't carry the registration call;
  > re-run `mix bloccs.compile` after upgrading to make it discoverable.
  """

  @registry Bloccs.NetworkRegistry

  @type entry :: %{
          network_id: atom(),
          supervisor: module(),
          pid: pid(),
          started_at: integer()
        }

  @doc """
  Register a running network. Called from the generated supervisor's `init/1`,
  so the registration is owned by (and cleaned up with) the supervisor process.
  Idempotent for the calling process.
  """
  @spec register(atom(), module()) :: :ok
  def register(network_id, supervisor_module) do
    meta = %{supervisor: supervisor_module, started_at: System.monotonic_time(:millisecond)}

    case Registry.register(@registry, network_id, meta) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @doc "List every running network."
  @spec list() :: [entry()]
  def list do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(&to_entry/1)
  end

  @doc "Look up a single running network by id."
  @spec lookup(atom()) :: {:ok, entry()} | :error
  def lookup(network_id) do
    case Registry.lookup(@registry, network_id) do
      [{pid, meta}] -> {:ok, to_entry({network_id, pid, meta})}
      [] -> :error
    end
  end

  defp to_entry({network_id, pid, meta}) do
    %{
      network_id: network_id,
      supervisor: meta.supervisor,
      pid: pid,
      started_at: meta.started_at
    }
  end
end
