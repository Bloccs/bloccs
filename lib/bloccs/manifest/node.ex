defmodule Bloccs.Manifest.Node do
  @moduledoc """
  A parsed node manifest (`.bloccs`).

  One node per file. The manifest is the canonical artifact agents read/write
  and the (future) canvas renders.
  """

  alias Bloccs.Manifest.{Effects, Port, Contract, Doc, Batch, Join, Rate}

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
          batch: Batch.t() | nil,
          join: Join.t() | nil,
          rate: Rate.t() | nil,
          delay_ms: pos_integer() | nil,
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
    :batch,
    :join,
    :rate,
    :delay_ms,
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

defmodule Bloccs.Manifest.Batch do
  @moduledoc """
  Batch / aggregate config from `[batch]`. Present only on aggregate nodes.

  When set, the node processes messages in **batches** rather than one at a time:
  its `pure_core` receives the **list** of payloads in the batch (not a single
  payload) and reduces them; its `effect_shell` emits a single aggregate result
  (or splits / drops, like any node). The batch flushes when it reaches `size`
  messages or after `timeout_ms` of idle — whichever comes first, so a partial
  batch is never stranded.
  """

  @type t :: %__MODULE__{
          size: pos_integer() | nil,
          timeout_ms: pos_integer() | nil
        }

  defstruct [:size, :timeout_ms]
end

defmodule Bloccs.Manifest.Join do
  @moduledoc """
  Join / correlation config from `[join]`. Present only on join nodes.

  A join node has **two or more** in-ports carrying distinct schemas. Arrivals
  are correlated by the value of the `on` field (a field name present in every
  input payload) — when all in-ports have produced a payload for the same key,
  the node's `pure_core` receives the map `%{port => payload}` and emits the
  joined result.

  - `on` — the correlation-key *field name* (not a predicate).
  - `timeout_ms` — how long to wait for the other side(s) before giving up.
  - `deadletter` — the name of an out-port; a partial match that times out is
    emitted there (as an `%{key, ports, payloads}` envelope) so nothing is lost.
    Optional — without it, a timed-out partial is dropped with a
    `[:bloccs, :join, :timeout]` event.
  """

  @type t :: %__MODULE__{
          on: String.t(),
          timeout_ms: pos_integer() | nil,
          deadletter: atom() | nil
        }

  @enforce_keys [:on]
  defstruct [:on, :timeout_ms, :deadletter]
end

defmodule Bloccs.Manifest.Rate do
  @moduledoc """
  Rate-limit (throttle) config from `[rate]`. Caps how fast a node's producer
  delivers messages downstream — `allowed` messages per `interval_ms` — using
  Broadway's built-in producer `rate_limiting`.
  """

  @type t :: %__MODULE__{
          allowed: pos_integer(),
          interval_ms: pos_integer()
        }

  @enforce_keys [:allowed, :interval_ms]
  defstruct [:allowed, :interval_ms]
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
