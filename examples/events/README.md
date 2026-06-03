# events — a webhook/event processor

The flagship bloccs example: a small, **real-shaped** pipeline of the kind every
backend eventually grows — receive an event, validate it, enrich it from an
external lookup, then branch on its type and fan out. It runs end-to-end on the
built-in **mock** effect backends, so there's nothing to install and no external
services. The same network runs against real HTTP + a real database by changing
config only — see [Going real](#going-real).

It exercises the whole bloccs toolbox in one flow: schema-typed edges, declared
HTTP + DB effects, a pure validation gate, retry + timeout, idempotency,
branching, fan-out, and structural coverage.

## The network

```
                                              ┌─▶ persist (DB)      → stored
webhook ─▶ ingest ─▶ validate ─▶ enrich ─▶ route ┤   (events table)
           (source)  (pure)     (HTTP,    (router)│
                                 retry,           └─▶ notify (HTTP)    → notified
                                 timeout,         │
                                 idempotent)      └──(unknown type)──▶ deadletter (DB) → dead
```

- `ingest` (source) — normalizes the raw event (`id`, lower-cased `type`, `payload`).
- `validate` (pure) — rejects an empty payload **in the pure core**, before any
  effect runs. No `[effects]` block at all.
- `enrich` (HTTP) — `GET`s an enrichment lookup. Declares `timeout_ms`, `retry`
  (exponential), and `idempotency` keyed on the event id — a replayed webhook is
  deduped *before* the lookup is made.
- `route` (router) — emits to `known` or `unknown` by event type.
- `persist` (DB) — inserts a known event into the `events` table.
- `notify` (HTTP) — `POST`s a downstream webhook. `route.known` fans out to
  **both** persist and notify.
- `deadletter` (DB) — records unknown-type events so nothing is silently dropped.

## Run it

From the bloccs project root (`app/bloccs`):

```sh
mix events.demo
```

Expected output:

```
network `events` running — pushing webhook events

  → pushed evt-1 (order.created)
  → pushed evt-2 (user.created)
  → pushed evt-3 (subscription.canceled)
  → pushed evt-1 (order.created)
  ← notified evt-2 (sent)
  ← notified evt-1 (sent)
  ← persisted evt-2
  ← dead-lettered evt-3
  ← persisted evt-1

events table (2 rows):
  #1  evt-2  user.created
  #3  evt-1  order.created

deadletter table (1 rows):
  #2  evt-3  subscription.canceled

(4 events pushed: 2 known → persisted + notified, 1 unknown → dead-lettered, 1 duplicate → deduped)
```

Four events in, three stored: two known events were persisted **and** notified
(the fan-out), one unknown type was dead-lettered, and the replayed `evt-1` was
deduped by the enrich node's declared idempotency — concurrency-safe, so even a
simultaneous duplicate can't slip through.

## Structural coverage

`mix events.demo` also records a `.bloccs-trace`. Report which ports and edges
the run actually exercised:

```sh
mix bloccs.coverage examples/events/networks/events.bloccs --trace events.bloccs-trace
```

Because the demo pushes both a known and an unknown event, every obligation is
reached (`100.0%`). Drop the `subscription.canceled` push from the demo and the
`route.unknown → deadletter.event` edge shows up as **unreached** — that's the
point: coverage is structural and real, not a guess.

## Using the bloccs CLI directly

```sh
mix bloccs.validate examples/events/networks/events.bloccs
mix bloccs.compile  examples/events/networks/events.bloccs   # emits source to _build/bloccs_generated/
```

(`mix bloccs.run` needs the port schemas registered and the two HTTP endpoints
stubbed; `mix events.demo` does both, so it's the way to run this network.)

## Going real

The node code never names a backend — it calls the facade
(`Bloccs.Effects.HTTP.get/2`, `DB.insert/3`). Selecting real backends is pure
config:

```elixir
config :bloccs, :effect_backends,
  http: Bloccs.Effects.HTTP.Req,    # real HTTP via Req
  db:   Bloccs.Effects.DB.Ecto      # real SQL via your Ecto repo

config :bloccs, Bloccs.Effects.DB.Ecto, repo: MyApp.Repo
```

Point `enrich`/`notify` at real hosts (and add those hosts to each node's
`[effects].http.allow`), wire the DB to your repo, and the same manifests run
unchanged. For a fully-wired real-HTTP-to-SQLite example, see
[`../real_backend`](../real_backend) (`mix price_watch.demo`).
