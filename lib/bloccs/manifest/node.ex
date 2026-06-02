defmodule Bloccs.Manifest.Node do
  @moduledoc """
  A parsed node manifest (`.bloccs`).

  One node per file. The manifest is the canonical artifact agents read/write
  and the (future) canvas renders.
  """

  alias Bloccs.Manifest.{Effects, Port, Contract, Doc}

  @type kind :: :source | :transform | :router | :sink

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          id: String.t(),
          version: String.t(),
          kind: kind(),
          doc: Doc.t() | nil,
          ports_in: %{atom() => Port.t()},
          ports_out: %{atom() => Port.t()},
          effects: Effects.t(),
          contract: Contract.t(),
          observability: %{optional(atom()) => term()}
        }

  @enforce_keys [:id, :version, :kind, :ports_in, :ports_out, :effects, :contract]
  defstruct [
    :path,
    :id,
    :version,
    :kind,
    :doc,
    :ports_in,
    :ports_out,
    :effects,
    :contract,
    observability: %{}
  ]

  @valid_kinds ~w(source transform router sink)a

  @doc """
  Cast a `kind` string to its atom form. Returns `{:ok, kind}` or `:error` for
  an unknown value — lets callers pattern-match instead of rescuing.
  """
  @spec cast_kind(String.t()) :: {:ok, kind()} | :error
  def cast_kind(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @valid_kinds, do: {:ok, atom}, else: :error
  rescue
    # value isn't an existing atom → definitely not a known kind
    ArgumentError -> :error
  end

  def cast_kind(_), do: :error

  @doc "Bang variant of `cast_kind/1`; raises `ArgumentError` on an unknown kind."
  @spec cast_kind!(String.t()) :: kind()
  def cast_kind!(value) do
    case cast_kind(value) do
      {:ok, kind} -> kind
      :error -> raise(ArgumentError, "unknown node kind #{inspect(value)}")
    end
  end

  @doc "The list of valid kinds."
  def kinds, do: @valid_kinds
end

defmodule Bloccs.Manifest.Doc do
  @moduledoc "Human-facing documentation block from `[doc]`: intent + owner."

  @type t :: %__MODULE__{
          intent: String.t() | nil,
          owner: String.t() | nil
        }

  defstruct [:intent, :owner]
end

defmodule Bloccs.Manifest.Port do
  @moduledoc """
  A node port. `schema` is a `"Name@N"` reference; `buffer` is the producer
  buffer size for input ports (ignored for output ports).
  """

  @type t :: %__MODULE__{
          name: atom(),
          schema: String.t(),
          buffer: pos_integer() | nil
        }

  @enforce_keys [:name, :schema]
  defstruct [:name, :schema, :buffer]
end

defmodule Bloccs.Manifest.Effects do
  @moduledoc """
  Declared effect capabilities.

  Each axis is either `nil` (not allowed at all) or a typed declaration:

  - `http` — `%{allow: [host], methods: [method]}`
  - `db`   — `%{allow: [scope_string]}` where scope is `"table:action"`
  - `time` — `"wall_clock"` | `"none"`
  - `random` — `"none"` | `"crypto"` | `"pseudo"`
  """

  @type http :: %{allow: [String.t()], methods: [String.t()]} | nil
  @type db :: %{allow: [String.t()]} | nil
  @type time :: String.t() | nil
  @type random :: String.t() | nil

  @type t :: %__MODULE__{
          http: http(),
          db: db(),
          time: time(),
          random: random()
        }

  defstruct http: nil, db: nil, time: nil, random: nil

  @doc "Returns the list of effect axes that are actively declared."
  @spec declared(t()) :: [:http | :db | :time | :random]
  def declared(%__MODULE__{} = e) do
    Enum.filter([:http, :db, :time, :random], fn axis ->
      case Map.fetch!(e, axis) do
        nil -> false
        "none" -> false
        _ -> true
      end
    end)
  end
end

defmodule Bloccs.Manifest.Contract do
  @moduledoc """
  The node contract: function refs, retry policy, timeout, idempotency.
  """

  @type mfa_ref :: %{module: module(), function: atom(), arity: pos_integer()}

  @type retry ::
          %{
            strategy: String.t(),
            max: non_neg_integer(),
            on: [String.t()],
            base_ms: pos_integer() | nil
          }
          | nil

  @type idempotency :: %{key: String.t()} | nil

  @type t :: %__MODULE__{
          pure_core: mfa_ref(),
          effect_shell: mfa_ref(),
          retry: retry(),
          timeout_ms: pos_integer() | nil,
          idempotency: idempotency()
        }

  @enforce_keys [:pure_core, :effect_shell]
  defstruct [:pure_core, :effect_shell, :retry, :timeout_ms, :idempotency]
end
