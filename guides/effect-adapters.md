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
