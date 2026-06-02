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
  Build a capability struct from a parsed node manifest.

  The backend module for each axis is resolved by layering, lowest precedence
  first:

  1. **Built-in defaults** — mock HTTP/DB, real wall-clock/RNG. Safe for tests.
  2. **App config** — `config :bloccs, :effect_backends, http: ..., db: ...`.
     This is how production selects the real adapters (`HTTP.Req`, `DB.Ecto`)
     without touching node source.
  3. **Per-call `:backends`** — a keyword override, mainly for tests that want
     a specific backend inline.

  Backend-specific configuration (e.g. the Ecto repo) is read by the backend
  itself from its own config key — see each adapter's docs.
  """
  @spec bind(Node.t(), keyword()) :: Capabilities.t()
  def bind(%Node{effects: e}, opts \\ []) do
    backends =
      default_backends()
      |> Keyword.merge(configured_backends())
      |> Keyword.merge(Keyword.get(opts, :backends, []))

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

  defp configured_backends do
    Application.get_env(:bloccs, :effect_backends, [])
  end

  defp build_axis(_axis, nil, _), do: Bloccs.Effects.Denied.Stub.new(:undeclared)
  defp build_axis(_axis, "none", _), do: Bloccs.Effects.Denied.Stub.new(:none)
  defp build_axis(axis, declared, backends), do: Keyword.fetch!(backends, axis).new(declared)

  @doc "Raise `Bloccs.Effects.Denied` with a useful message."
  @spec deny!(atom(), String.t()) :: no_return()
  def deny!(axis, detail), do: raise(Denied, axis: axis, detail: detail)
end

defmodule Bloccs.Effects.Denied.Stub do
  # The capability stub installed for axes that are NOT declared on a node.
  # Any call to it raises `Bloccs.Effects.Denied`. Internal detail.
  @moduledoc false

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
