defmodule Bloccs.Effects.HTTP.Mock do
  @moduledoc """
  Mock HTTP backend. Refuses non-allowed hosts. Returns stubbed responses
  registered per-node via `stub/3`.

  Designed for v0.1 tests. Replace with a `Req`-backed adapter at v0.2.
  """

  alias Bloccs.Effects

  @behaviour Bloccs.Effects.HTTP

  defstruct allow: [], methods: [], stubs: nil

  @typep t :: %__MODULE__{allow: [String.t()], methods: [String.t()], stubs: pid() | nil}

  @impl true
  @doc "Build the capability struct from a `[effects].http` declaration."
  def new(%{allow: allow, methods: methods}) do
    %__MODULE__{allow: allow, methods: methods, stubs: stubs_pid()}
  end

  @doc """
  Register a stub response for a method + URL pattern. URL match is a literal
  string match for v0.1.
  """
  @spec stub(String.t(), String.t(), (map() -> term())) :: :ok
  def stub(method, url, response_fun) when is_function(response_fun, 1) do
    Agent.update(stubs_pid(), fn stubs ->
      Map.put(stubs, {String.upcase(method), url}, response_fun)
    end)
  end

  @doc "Clear all stubs. Test-only."
  def reset, do: Agent.update(stubs_pid(), fn _ -> %{} end)

  @impl true
  @spec post(t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def post(%__MODULE__{} = cap, url, body), do: dispatch(cap, "POST", url, body)

  @impl true
  @spec get(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(%__MODULE__{} = cap, url), do: dispatch(cap, "GET", url, nil)

  defp dispatch(%__MODULE__{allow: allow, methods: methods}, method, url, body) do
    case Bloccs.Effects.HTTP.Allowlist.check(allow, methods, method, url) do
      :ok -> run_stub(method, url, body)
      {:deny, detail} -> Effects.deny!(:http, detail)
    end
  end

  defp run_stub(method, url, body) do
    case Agent.get(stubs_pid(), &Map.get(&1, {method, url})) do
      nil ->
        {:error, {:no_stub, method, url}}

      fun ->
        try do
          {:ok, fun.(%{method: method, url: url, body: body})}
        rescue
          e -> {:error, e}
        end
    end
  end

  defp stubs_pid do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, pid} = Agent.start_link(fn -> %{} end, name: __MODULE__)
        pid

      pid ->
        pid
    end
  end
end
