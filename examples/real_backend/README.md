# price_watch — a real-backend bloccs example

A standalone app that runs a [bloccs](../../) network end-to-end against **real
backends, with zero external services**:

- **Real HTTP** — the `fetch_quote` node makes actual HTTP requests (over a
  socket, via `Bloccs.Effects.HTTP.Req`) to a local Bandit stub that stands in
  for an external quote API.
- **Real SQLite** — the `record_quote` node persists results to a local SQLite
  file via `Bloccs.Effects.DB.Ecto` (schemaless `INSERT`).

It consumes `bloccs` as a path dependency — exactly how a downstream project
would — and brings its own Ecto/SQLite stack, demonstrating that bloccs forces
no database dependency on you.

## The network

```
request ─▶ [fetch_quote]  ──quote_fetched──▶ [record_quote] ─▶ done
            HTTP.Req GET                       DB.Ecto INSERT
            localhost stub                     SQLite
```

- `networks/price_watch.bloccs` — topology
- `nodes/fetch_quote.bloccs` + `lib/nodes/fetch_quote.ex` — HTTP effect node
  (declares `http = { allow = ["localhost"], methods = ["GET"] }`, plus
  `timeout_ms` + `retry`)
- `nodes/record_quote.bloccs` + `lib/nodes/record_quote.ex` — DB effect node
  (declares `db = { allow = ["quotes:insert"] }`, plus `idempotency` on
  `request_id`)

## How the real backends get selected

Nodes call the backend-agnostic facade (`HTTP.get`, `DB.insert`). The *real*
backends are chosen entirely in `config/config.exs` — no node code changes:

```elixir
config :bloccs, :effect_backends,
  http: Bloccs.Effects.HTTP.Req,
  db: Bloccs.Effects.DB.Ecto

config :bloccs, Bloccs.Effects.DB.Ecto, repo: PriceWatch.Repo
```

Drop those lines and bloccs falls back to its built-in mocks.

## Prerequisites

- Elixir ~> 1.18 / OTP 27
- A C compiler + `make` (this example builds the SQLite NIF from source via
  `config :exqlite, force_build: true`, which avoids glibc-version mismatches in
  the precompiled binary)

## Run it

```sh
mix deps.get
mix price_watch.demo
```

Expected output:

```
network `price_watch` running — pushing quote requests

  → pushed USD (req-1)
  → pushed BTC (req-2)
  → pushed USD (req-1)
  ← recorded USD = 768
  ← recorded BTC = 562

quotes table (2 rows):
  id | request_id | symbol | price | recorded_at
  1  | req-1      | USD    | 768   | ...
  2  | req-2      | BTC    | 562   | ...

(3 requests pushed, 2 rows written — the duplicate req-1 was deduped)
```

Three requests in, two rows out: the repeated `req-1` is dropped by the
`record_quote` node's declared idempotency. The prices come from real HTTP calls
to the local stub; the rows are real SQLite writes (set `log: :debug` on the
repo in `config/config.exs` to watch the SQL).

## Using the bloccs CLI directly

The bloccs Mix tasks work here too:

```sh
mix bloccs.validate networks/price_watch.bloccs
mix bloccs.compile  networks/price_watch.bloccs   # emits source to _build/bloccs_generated/
mix bloccs.run      networks/price_watch.bloccs --message '{"symbol":"ETH","request_id":"r9"}'
```

`mix bloccs.run` boots the app (starting the Repo + stub API), compiles and
starts the supervision tree, and feeds the JSON message into the exposed
`request` port — a full real-backend round trip from one command.
