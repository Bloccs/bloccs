# Effect adapters

Effects in bloccs are **declared capabilities**, not function calls. A node's
`[effects]` block says *what* it may reach; the runtime materializes that into a
capability struct, and the node's effect-shell calls a **facade** that dispatches
to whichever **backend** is bound. Swapping mock → real is a config change, not a
source edit.

```
node effect-shell ──▶ Bloccs.Effects.HTTP.post/3   (facade: pure dispatch)
                              │
                              ▼  %mod{} = cap → mod.post(cap, …)
                     Bloccs.Effects.HTTP.Mock   (tests)
                     Bloccs.Effects.HTTP.Req     (production)
                     <your module>               (custom)
```

The four axes each have a facade + behaviour:

| Axis | Facade / behaviour | Built-in backends |
|---|---|---|
| HTTP | `Bloccs.Effects.HTTP` | `…HTTP.Mock`, `…HTTP.Req` |
| DB | `Bloccs.Effects.DB` | `…DB.Mock`, `…DB.Ecto` |
| Time | `Bloccs.Effects.Time` | `…Time.System` (real wall clock) |
| Random | `Bloccs.Effects.Random` | `…Random.System` |

## Selecting backends

`Bloccs.Effects.bind/2` resolves each axis by layering, lowest precedence first:

1. **Built-in defaults** — mock HTTP/DB, real clock/RNG. Safe for tests.
2. **App config** — `config :bloccs, :effect_backends, …`.
3. **Per-call `:backends`** — a keyword override (used by tests).

Production config:

```elixir
config :bloccs, :effect_backends,
  http: Bloccs.Effects.HTTP.Req,
  db: Bloccs.Effects.DB.Ecto
```

No node source changes — nodes always call the facade.

## HTTP — `Bloccs.Effects.HTTP.Req`

Built on [Req](https://hexdocs.pm/req). The declared `allow` hosts + `methods`
are enforced by `Bloccs.Effects.HTTP.Allowlist` **before any request leaves the
VM** — the identical check the mock runs — so the capability guarantee holds in
production. A denied call raises `Bloccs.Effects.Denied` (the runtime turns it
into a failed message).

`req` is an **optional** dependency of bloccs — add it to *your* app to use this
backend (mirrors how `DB.Ecto` expects you to bring Ecto):

```elixir
# in your app's deps
{:req, "~> 0.5"}

# config
config :bloccs, :effect_backends, http: Bloccs.Effects.HTTP.Req
# optional: extra Req options (timeouts, retries, auth, a test adapter)
config :bloccs, Bloccs.Effects.HTTP.Req, req_options: [retry: :transient]
```

If `:req` isn't present, selecting `HTTP.Req` raises a clear error pointing here.

Results: `2xx → {:ok, body}` (a JSON object decodes to a map); `non-2xx →
{:error, {:http_status, status, body}}`; transport failure → `{:error,
exception}`.

## DB — `Bloccs.Effects.DB.Ecto`

Writes through an Ecto repo with **no compile-time Ecto dependency** — it calls
`repo.insert_all/2` via runtime dispatch, so the published `bloccs` package never
forces `ecto`/`postgrex` on consumers who don't use the DB axis.

```elixir
# in your app
{:ecto_sql, "~> 3.0"},
{:postgrex, ">= 0.0.0"}

# config
config :bloccs, :effect_backends, db: Bloccs.Effects.DB.Ecto
config :bloccs, Bloccs.Effects.DB.Ecto, repo: MyApp.Repo
```

The `"table:insert"` scope is enforced (raises `Denied` on violation). Success
returns `{:ok, row}`; a repo error returns `{:error, exception}`.

To echo database-generated columns (e.g. an autoincrement `id`), add a
`returning` list — it's applied to every insert, so set it to your primary key:

```elixir
config :bloccs, Bloccs.Effects.DB.Ecto, repo: MyApp.Repo, returning: [:id]
```

The generated values are merged into the returned `row`.

### Reads

The DB axis also reads, behind a `"table:read"` scope:

```elixir
db = { allow = ["items:read", "items:insert"] }
```

```elixir
{:ok, row}  = DB.get(ctx.effects.db, :items, id)          # by primary key (id), or nil
{:ok, rows} = DB.all(ctx.effects.db, :items, %{group: "x"}) # ANDed equality, [] = all
{:ok, row}  = DB.one(ctx.effects.db, :items, %{slug: "x"})  # one, nil, or {:error, :multiple_results}
```

Rows come back as **string-keyed maps** from both `DB.Mock` and `DB.Ecto`, so the
same node logic works against either. A read is an effect — it lives in
`effect_shell`, never `pure_core`. To drive *pure* logic with the result, merge it
into the payload and emit to a downstream node; for request/response, read and
reply in the one shell.

`DB.Ecto` runs reads as a parameterized `repo.query!/2` (the only path needing no
compile-time `Ecto.Query` macro). The filter is ANDed equality only; placeholders
are picked from `repo.__adapter__/0` (`$n` for Postgres, `?` otherwise) and
identifiers are double-quoted, so **Postgres and SQLite3** are supported — for
other dialects (e.g. MySQL back-ticks) or richer queries (`IN`, ranges, ordering),
implement the `Bloccs.Effects.DB` behaviour directly.

### Update & delete

Behind `"table:update"` / `"table:delete"` scopes, keyed by primary id:

```elixir
db = { allow = ["items:update", "items:delete"] }
```

```elixir
{:ok, 1} = DB.update(ctx.effects.db, :items, id, %{slug: "y"})        # set a literal
{:ok, 1} = DB.update(ctx.effects.db, :items, id, %{votes: {:inc, 1}}) # atomic increment
{:ok, 1} = DB.delete(ctx.effects.db, :items, id)
```

Both return `{:ok, rows_affected}` (0 or 1). The `{:inc, n}` change compiles to
`SET col = col + n` — a **read-free atomic increment** (a negative `n`
decrements), the correct primitive for counters: no read-modify-write race.

### Transactions

`DB.transaction/2` runs a unit of work atomically — a function or a list of ops:

```elixir
# function form: db is the same capability; inner calls run in the transaction
{:ok, :ok} =
  DB.transaction(ctx.effects.db, fn db ->
    {:ok, _} = DB.insert(db, :votes, item_id: id, voter: who)
    {:ok, 1} = DB.update(db, :items, id, %{votes: {:inc, 1}})
    {:ok, :ok}
  end)

# declarative form: ops run in order, short-circuiting on the first error
{:ok, [_vote, 1]} =
  DB.transaction(ctx.effects.db, [
    {:insert, :votes, [item_id: id, voter: who]},
    {:update, :items, id, %{votes: {:inc, 1}}}
  ])
```

Returning `{:error, reason}` from the function (or any op failing, as
`{:error, {index, reason}}`) rolls everything back; a raise also rolls back and
re-raises. Each inner op is scope-checked like a standalone call. `DB.Ecto` maps
this to `repo.transaction/1` + `repo.rollback/1`; `DB.Mock` snapshots its store
and restores it on rollback, so tests get real atomicity with no database.

## Writing a custom backend

Implement the axis behaviour. Enforce the declared scope yourself, then do I/O.

```elixir
defmodule MyApp.Effects.HTTP.Finch do
  @behaviour Bloccs.Effects.HTTP
  alias Bloccs.Effects.HTTP.Allowlist

  defstruct allow: [], methods: []

  @impl true
  def new(%{allow: allow, methods: methods}),
    do: %__MODULE__{allow: allow, methods: methods}

  @impl true
  def post(%__MODULE__{allow: a, methods: m} = _cap, url, body) do
    case Allowlist.check(a, m, "POST", url) do
      :ok -> # … your client …
        {:ok, %{}}
      {:deny, detail} -> Bloccs.Effects.deny!(:http, detail)
    end
  end

  @impl true
  def get(_cap, _url), do: {:ok, %{}}
end
```

Then point config at it: `config :bloccs, :effect_backends, http:
MyApp.Effects.HTTP.Finch`. Reuse `Bloccs.Effects.HTTP.Allowlist` to keep the
capability guarantee.
