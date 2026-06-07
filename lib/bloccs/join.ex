defmodule Bloccs.Join do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > Infrastructure called by compiler-generated pipelines — not part of the
  > stable user API. You drive this through manifests, not by calling it directly;
  > signatures may change between minor versions.

  Correlation buffer for `[join]` nodes — infrastructure, like `Bloccs.Idempotency`.

  A join node has two or more in-ports carrying distinct schemas. Each in-port
  compiles to its own Broadway pipeline; every arrival is handed here and stashed
  by correlation key (the value of the node's `[join].on` field). When **all** of
  a node's in-ports have produced a payload for the same key, the partial match
  is removed and returned complete — the arriving pipeline then runs the node's
  contract over the correlated `%{port => payload}` map and dispatches the result.

  ## Timeout / deadletter

  A partial match that is not completed within the node's `[join].timeout_ms` is
  swept: if the node declared `[join].deadletter = "port"`, the partial is emitted
  there as an `%{key, present, payloads}` envelope (nothing is lost); otherwise it
  is dropped with a `[:bloccs, :join, :timeout]` event.

  State lives in a public ETS table owned by this GenServer. Correlation merges
  run inside the server so the read-modify-write stays atomic; the sweep runs on
  a timer (configurable via `:bloccs, :join_sweep_ms`, default 1s) and
  `sweep_now/0` forces one synchronously (used by tests).
  """

  use GenServer

  alias Bloccs.Router

  @table :bloccs_join
  @default_sweep_ms 1_000

  @type scope :: {atom(), atom()}
  @type config :: %{
          required: MapSet.t(atom()),
          on: String.t(),
          timeout_ms: pos_integer() | nil,
          deadletter: atom() | nil
        }

  @doc "Start the buffer (started under the bloccs application supervisor)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register a join node's correlation config. Called from a generated network
  supervisor at boot (alongside `Router.register/2`). `scope` is `{network, node}`.
  """
  @spec register(scope(), config()) :: :ok
  def register(scope, config), do: GenServer.call(__MODULE__, {:register, scope, config})

  @doc """
  Record an arrival on `port` for join `scope`, carrying the arriving message's
  `lineage` (`Bloccs.Lineage.t/0` or `nil`). Returns `{:complete, payloads,
  parents}` — a `%{port => payload}` map plus the list of correlated arrivals'
  lineages (the joined output's parents) — once every required in-port has
  arrived for the arrival's correlation key; `:partial` while still waiting; or
  `{:error, reason}` (`:no_config` / `:no_key`).
  """
  @spec arrive(scope(), atom(), map(), Bloccs.Lineage.t() | nil) ::
          {:complete, %{atom() => map()}, [Bloccs.Lineage.t()]}
          | :partial
          | {:error, :no_config | :no_key}
  def arrive(scope, port, payload, lineage \\ nil),
    do: GenServer.call(__MODULE__, {:arrive, scope, port, payload, lineage})

  @doc "Force a sweep synchronously (deadletter/drop expired partials). Test helper."
  @spec sweep_now() :: :ok
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  @doc "Drop all buffered partial matches (keeps registered configs). Test-only."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ---------------- GenServer ----------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table, configs: %{}}}
  end

  @impl true
  def handle_call({:register, scope, config}, _from, state) do
    {:reply, :ok, %{state | configs: Map.put(state.configs, scope, config)}}
  end

  def handle_call({:arrive, scope, port, payload, lineage}, _from, state) do
    case Map.fetch(state.configs, scope) do
      :error ->
        {:reply, {:error, :no_config}, state}

      {:ok, config} ->
        {:reply, do_arrive(scope, port, payload, lineage, config), state}
    end
  end

  def handle_call(:sweep, _from, state) do
    sweep(state)
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    schedule_sweep()
    {:noreply, state}
  end

  # ---------------- correlation ----------------

  defp do_arrive(scope, port, payload, lineage, %{on: on, required: required}) do
    case fetch_field(payload, on) do
      :none ->
        {:error, :no_key}

      {:ok, key} ->
        %{ports: cur_ports, lineages: cur_lineages} = current_row(scope, key)
        ports = Map.put(cur_ports, port, payload)
        lineages = Map.put(cur_lineages, port, lineage)

        if MapSet.subset?(required, MapSet.new(Map.keys(ports))) do
          :ets.delete(@table, {scope, key})
          {:complete, ports, lineages |> Map.values() |> Enum.reject(&is_nil/1)}
        else
          :ets.insert(@table, {{scope, key}, %{ports: ports, lineages: lineages, ts: now_ms()}})
          :partial
        end
    end
  end

  defp current_row(scope, key) do
    case :ets.lookup(@table, {scope, key}) do
      [{_, %{ports: ports} = row}] -> %{ports: ports, lineages: Map.get(row, :lineages, %{})}
      [] -> %{ports: %{}, lineages: %{}}
    end
  end

  # ---------------- sweep / deadletter ----------------

  defp sweep(%{configs: configs}) do
    now = now_ms()

    :ets.tab2list(@table)
    |> Enum.each(fn {{scope, key}, %{ports: ports, ts: ts} = row} ->
      with {:ok, %{timeout_ms: t} = config} when is_integer(t) <- Map.fetch(configs, scope),
           true <- now - ts > t do
        expire(scope, key, ports, Map.get(row, :lineages, %{}), config)
        :ets.delete(@table, {scope, key})
      else
        _ -> :ok
      end
    end)
  end

  defp expire({network, node} = _scope, key, ports, _lineages, %{deadletter: nil}) do
    :telemetry.execute(
      [:bloccs, :join, :timeout],
      %{present: map_size(ports)},
      %{network: network, node: node, key: key}
    )
  end

  defp expire({network, node} = _scope, key, ports, lineages, %{deadletter: port}) do
    envelope = %{
      "key" => key,
      "present" => ports |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      "payloads" => ports
    }

    # The dead-lettered partial's parents are whichever arrivals did show up.
    ctx = lineages |> Map.values() |> Enum.reject(&is_nil/1) |> Bloccs.Lineage.merge()
    _ = Router.dispatch(network, node, port, envelope, ctx)
    :ok
  end

  # Payloads may carry string or atom keys; try the declared field both ways.
  defp fetch_field(data, field) when is_map(data) do
    cond do
      Map.has_key?(data, field) -> {:ok, Map.fetch!(data, field)}
      (atom = existing_atom(field)) && Map.has_key?(data, atom) -> {:ok, Map.fetch!(data, atom)}
      true -> :none
    end
  end

  defp fetch_field(_data, _field), do: :none

  defp existing_atom(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  defp schedule_sweep do
    interval = Application.get_env(:bloccs, :join_sweep_ms, @default_sweep_ms)
    Process.send_after(self(), :sweep, interval)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
