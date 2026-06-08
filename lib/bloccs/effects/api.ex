defmodule Bloccs.Effects.HTTP do
  @moduledoc """
  HTTP effect facade + backend behaviour.

  A node's effect-shell calls `Bloccs.Effects.HTTP.post/3` / `get/2` against the
  capability struct in `ctx.effects.http`. The facade dispatches to whichever
  backend built that struct — `Bloccs.Effects.HTTP.Mock` in tests,
  `Bloccs.Effects.HTTP.Req` in production — so node source never names a
  concrete backend. Backends `@behaviour Bloccs.Effects.HTTP`.

  Allowlist/method enforcement is the backend's responsibility (every shipped
  backend enforces it before doing I/O); the facade is pure dispatch.
  """

  @typedoc "A `[effects].http` declaration: allowed hosts + methods."
  @type declaration :: %{allow: [String.t()], methods: [String.t()]}
  @typedoc "A backend capability struct (e.g. %HTTP.Mock{} / %HTTP.Req{})."
  @type cap :: struct()
  @type response :: {:ok, map()} | {:error, term()}

  @callback new(declaration()) :: cap()
  @callback post(cap(), String.t(), term()) :: response()
  @callback get(cap(), String.t()) :: response()

  @doc "POST `body` to `url` through the bound HTTP backend."
  @spec post(cap(), String.t(), term()) :: response()
  def post(%mod{} = cap, url, body), do: mod.post(cap, url, body)

  @doc "GET `url` through the bound HTTP backend."
  @spec get(cap(), String.t()) :: response()
  def get(%mod{} = cap, url), do: mod.get(cap, url)
end

defmodule Bloccs.Effects.DB do
  @moduledoc """
  DB effect facade + backend behaviour.

  Nodes call `Bloccs.Effects.DB.insert/3` / `get/3` / `all/3` / `one/3` against
  `ctx.effects.db`; the facade dispatches to the bound backend (`DB.Mock` in
  tests, `DB.Ecto` against a real repo in production). Scope enforcement
  (`"table:action"`, where action is `insert` or `read`) is the backend's job.
  Backends `@behaviour Bloccs.Effects.DB`.

  ## Reads

  `get/3` looks a row up by primary key (`id`); `all/3` and `one/3` filter by a
  **restricted equality spec** — a map of `column => value`, ANDed (deliberately
  not a query language). All three require a `"table:read"` scope and return rows
  as **string-keyed maps**, regardless of backend. Reads belong in `effect_shell`
  (a read touches the world); feed the result into pure logic by emitting the
  enriched payload to a downstream node, or read-and-reply in one shell for
  request/response.
  """

  @type declaration :: %{allow: [String.t()]}
  @type cap :: struct()
  @type table :: atom() | String.t()
  @type attrs :: keyword() | map()
  @typedoc "An ANDed equality filter: `%{column => value}`. Empty matches all."
  @type filter :: map()
  @type row :: %{optional(String.t()) => term()}

  @callback new(declaration()) :: cap()
  @callback insert(cap(), table(), attrs()) :: {:ok, map()} | {:error, term()}
  @callback get(cap(), table(), id :: term()) :: {:ok, row() | nil} | {:error, term()}
  @callback all(cap(), table(), filter()) :: {:ok, [row()]} | {:error, term()}
  @callback one(cap(), table(), filter()) ::
              {:ok, row() | nil} | {:error, :multiple_results | term()}

  @doc "Insert `attrs` into `table` through the bound DB backend."
  @spec insert(cap(), table(), attrs()) :: {:ok, map()} | {:error, term()}
  def insert(%mod{} = cap, table, attrs), do: mod.insert(cap, table, attrs)

  @doc "Fetch the row in `table` whose primary key (`id`) is `id`, or `nil`."
  @spec get(cap(), table(), term()) :: {:ok, row() | nil} | {:error, term()}
  def get(%mod{} = cap, table, id), do: mod.get(cap, table, id)

  @doc "Fetch every row in `table` matching `filter` (empty filter = all rows)."
  @spec all(cap(), table(), filter()) :: {:ok, [row()]} | {:error, term()}
  def all(%mod{} = cap, table, filter \\ %{}), do: mod.all(cap, table, filter)

  @doc """
  Fetch the single row in `table` matching `filter`. Returns `{:ok, nil}` for no
  match and `{:error, :multiple_results}` if more than one matches.
  """
  @spec one(cap(), table(), filter()) :: {:ok, row() | nil} | {:error, term()}
  def one(%mod{} = cap, table, filter), do: mod.one(cap, table, filter)
end

defmodule Bloccs.Effects.Time do
  @moduledoc """
  Time effect facade + backend behaviour. Nodes call `Bloccs.Effects.Time.now/1`
  against `ctx.effects.time`. Default backend is the real wall clock
  (`Time.System`); tests can bind a frozen-clock backend.
  """

  @type cap :: struct()

  @callback new(term()) :: cap()
  @callback now(cap()) :: DateTime.t()

  @doc "Current time through the bound clock backend."
  @spec now(cap()) :: DateTime.t()
  def now(%mod{} = cap), do: mod.now(cap)
end

defmodule Bloccs.Effects.Random do
  @moduledoc """
  Random effect facade + backend behaviour. Nodes call
  `Bloccs.Effects.Random.int/2` against `ctx.effects.random`.
  """

  @type cap :: struct()

  @callback new(term()) :: cap()
  @callback int(cap(), pos_integer()) :: pos_integer()

  @doc "A random integer in `1..n` through the bound RNG backend."
  @spec int(cap(), pos_integer()) :: pos_integer()
  def int(%mod{} = cap, n), do: mod.int(cap, n)
end
