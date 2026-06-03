# tour — bloccs core concepts, one rung at a time

A guided, three-rung tour of the core ideas. Every rung is a runnable network
with its own demo task, and the whole thing runs on the built-in **mock** effect
backends — no external services, no extra dependencies.

```sh
cd examples/tour
mix deps.get
mix tour.hello       # rung 1
mix tour.pipeline    # rung 2
mix tour.branching   # rung 3
```

## Rung 1 — `mix tour.hello`

One **pure node**. Introduces the whole vocabulary: a *node* with an input and
output *port*, each carrying a versioned *schema*; a *pure core* (`transform/2`)
that computes; an *effect shell* (`execute/2`) that here only emits; and the
*network* that wires it up. Shows the full **parse → validate → compile → run**
loop on the simplest possible graph.

```
entry ─▶ [greeter] ─▶ exit
         (pure)
```

## Rung 2 — `mix tour.pipeline`

Two nodes joined by an **edge**, and the first **effect**. `accept` (pure)
normalizes a word and emits it; the edge carries it — schema-checked — to
`define`, whose effect shell makes an HTTP lookup. `define` declares
`http = { allow = ["dictionary.local"], methods = ["GET"] }`; calling anything
else would be refused. The demo stubs the mock HTTP backend; real backends are a
config swap (see [`../events`](../events) and [`../real_backend`](../real_backend)).

```
request ─▶ [accept] ──word──▶ [define] ─▶ definition
           (pure)             (HTTP effect)
```

**See it reject a bad graph.** `networks/pipeline_mismatch.bloccs` is the same
pipeline with one edge deliberately mis-typed (`accept` emits `WordRequest@1`
into a `define` in-port that expects `Definition@1`). It never compiles:

```sh
mix bloccs.validate networks/pipeline_mismatch.bloccs
# ✗ … edge accept.word → define.word schema mismatch:
#     accept.word=WordRequest@1 but define.word=Definition@1
```

That's the point of typed edges — the mismatch is caught before the network
starts, not in production.

## Rung 3 — `mix tour.branching`

A **router** and **fan-out**. `classify` sends each message out one of two ports
(`ok` / `flagged`). The network fans `ok` out to *two* sinks (archive + ack) and
routes `flagged` to a third (review) — one node, multiple typed out-ports, and an
edge that delivers to more than one target.

```
                 ┌─▶ [archive] ─▶ archived
message ─▶ [classify] ┤
          (router) │  └─▶ [ack] ─────▶ acked
                   │
                   └──(flagged)──▶ [review] ─▶ queued
```

## Where next

- [`../events`](../events) — the same ideas at realistic scale: HTTP + DB
  effects, retry, timeout, idempotency, branching, fan-out, and coverage.
- [`../real_backend`](../real_backend) — swap the mock effects for real HTTP
  (Req) and a real database (Ecto/SQLite).
- The [guides](../../guides) — concepts, the manifest reference, and architecture.
