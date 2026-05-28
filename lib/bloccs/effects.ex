defmodule Bloccs.Effects do
  @moduledoc """
  Declared effect capabilities materialized at runtime.

  Each node's `[effects]` block becomes a `%Bloccs.Effects.Capabilities{}`
  struct injected into the per-message context. The struct's fields refuse
  out-of-scope calls — that's the runtime half of the "declared capabilities"
  guarantee. The compile-time half lives in `Bloccs.Node` (AST warning).

  v0.1 ships only mock backends. Real HTTP / DB / SMTP adapters arrive in v0.2.
  """

  alias Bloccs.Manifest.Node

  defmodule Denied do
    defexception [:axis, :detail]

    @impl true
    def message(%{axis: axis, detail: detail}),
      do: "bloccs effect denied: #{inspect(axis)} — #{detail}"
  end

  defmodule Capabilities do
    @moduledoc "Effect capability struct injected into a `Bloccs.Context`."

    @type t :: %__MODULE__{
            http: term(),
            db: term(),
            time: term(),
            random: term()
          }

    defstruct http: nil, db: nil, time: nil, random: nil
  end

  @doc """
  Build a capability struct from a parsed node manifest. Uses the v0.1 mock
  backends unless overridden via `:backends`.
  """
  @spec bind(Node.t(), keyword()) :: Capabilities.t()
  def bind(%Node{effects: e}, opts \\ []) do
    backends =
      Keyword.merge(default_backends(), Keyword.get(opts, :backends, []))

    %Capabilities{
      http: build_axis(:http, e.http, backends),
      db: build_axis(:db, e.db, backends),
      time: build_axis(:time, e.time, backends),
      random: build_axis(:random, e.random, backends)
    }
  end

  defp default_backends do
    [
      http: Bloccs.Effects.HTTP.Mock,
      db: Bloccs.Effects.DB.Mock,
      time: Bloccs.Effects.Time.System,
      random: Bloccs.Effects.Random.System
    ]
  end

  defp build_axis(_axis, nil, _), do: Bloccs.Effects.Denied.Stub.new(:undeclared)
  defp build_axis(_axis, "none", _), do: Bloccs.Effects.Denied.Stub.new(:none)
  defp build_axis(axis, declared, backends), do: Keyword.fetch!(backends, axis).new(declared)

  @doc "Raise `Bloccs.Effects.Denied` with a useful message."
  @spec deny!(atom(), String.t()) :: no_return()
  def deny!(axis, detail), do: raise(Denied, axis: axis, detail: detail)
end

defmodule Bloccs.Effects.Denied.Stub do
  @moduledoc """
  The capability stub installed for axes that are NOT declared on a node.

  Any call to it raises `Bloccs.Effects.Denied`.
  """

  defstruct [:reason]

  def new(reason), do: %__MODULE__{reason: reason}

  @spec post(t(), term(), term()) :: no_return()
  def post(_stub, _, _), do: Bloccs.Effects.deny!(:http, "axis not declared")

  @spec get(t(), term()) :: no_return()
  def get(_stub, _), do: Bloccs.Effects.deny!(:http, "axis not declared")

  @spec insert(t(), term(), term()) :: no_return()
  def insert(_stub, _, _), do: Bloccs.Effects.deny!(:db, "axis not declared")

  @spec now(t()) :: no_return()
  def now(_stub), do: Bloccs.Effects.deny!(:time, "axis not declared")

  @spec int(t(), term()) :: no_return()
  def int(_stub, _), do: Bloccs.Effects.deny!(:random, "axis not declared")

  @type t :: %__MODULE__{reason: atom()}
end
