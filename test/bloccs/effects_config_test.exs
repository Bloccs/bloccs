defmodule Bloccs.EffectsConfigTest do
  @moduledoc "Backend selection: defaults < app config < per-call :backends."

  use ExUnit.Case, async: false

  alias Bloccs.{Effects, Parser}

  defmodule FakeHTTP do
    @behaviour Bloccs.Effects.HTTP
    defstruct [:declared]
    @impl true
    def new(declared), do: %__MODULE__{declared: declared}
    @impl true
    def post(_, _, _), do: {:ok, %{from: :fake}}
    @impl true
    def get(_, _), do: {:ok, %{from: :fake}}
  end

  defmodule OtherHTTP do
    @behaviour Bloccs.Effects.HTTP
    defstruct [:declared]
    @impl true
    def new(declared), do: %__MODULE__{declared: declared}
    @impl true
    def post(_, _, _), do: {:ok, %{from: :other}}
    @impl true
    def get(_, _), do: {:ok, %{from: :other}}
  end

  @manifest ~S"""
  [node]
  id = "cfg"
  version = "0.1.0"
  kind = "transform"

  [ports.in]
  in_req = { schema = "Req@1" }

  [ports.out]
  out_ok = { schema = "Resp@1" }

  [effects]
  http = { allow = ["api.stripe.com"], methods = ["POST"] }

  [contract]
  pure_core = "Bloccs.Stub.transform/2"
  effect_shell = "Bloccs.Stub.execute/2"
  """

  setup do
    {:ok, node} = Parser.parse_node_string(@manifest)
    on_exit(fn -> Application.delete_env(:bloccs, :effect_backends) end)
    %{node: node}
  end

  test "defaults to the mock HTTP backend", %{node: node} do
    Application.delete_env(:bloccs, :effect_backends)
    caps = Effects.bind(node)
    assert %Bloccs.Effects.HTTP.Mock{} = caps.http
  end

  test "app config overrides the default backend", %{node: node} do
    Application.put_env(:bloccs, :effect_backends, http: FakeHTTP)
    caps = Effects.bind(node)
    assert %FakeHTTP{declared: %{allow: ["api.stripe.com"]}} = caps.http
  end

  test "per-call :backends overrides app config", %{node: node} do
    Application.put_env(:bloccs, :effect_backends, http: FakeHTTP)
    caps = Effects.bind(node, backends: [http: OtherHTTP])
    assert %OtherHTTP{} = caps.http
  end
end
