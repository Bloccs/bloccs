# Recipes

End-to-end shapes you can copy and adapt. Each one is a real bloccs network: node
manifests plus a network manifest, using only shipped primitives. For the meaning
of each key, see the [manifest reference](manifest-reference.md); for a guided
first build, see [getting started](getting-started.md).

These recipes describe bloccs' sweet spot: a *graph* of typed stages with scoped
side effects and back-pressure between them. If your problem is a single pipeline,
reach for Broadway directly; if the unit of work must survive restarts, see
[Durability: Oban at the edges](#durability-oban-at-the-edges) below.

- [Bulk classification through a rate-limited model](#bulk-classification-through-a-rate-limited-model)
- [Multi-stage RAG](#multi-stage-rag)
- [Entering a network from a web request](#entering-a-network-from-a-web-request)
- [Durability: Oban at the edges](#durability-oban-at-the-edges)

---

## Bulk classification through a rate-limited model

Triage a high volume of items through a model that has a request budget. The win
over chained jobs is **cross-stage back-pressure**: a bounded in-port on the
classifier parks the producer when the model can't keep up, and `[rate]` caps how
fast items are handed to it — so a burst upstream never stampedes the model.

The model is reached through the node's declared **`http` effect** (there is no
`model` effect axis); the allowlist is the only place classification is permitted
to call out.

```toml
# nodes/classify.bloccs — transform, rate-limited, back-pressured
[node]
id      = "classify"
version = "0.1.0"
kind    = "transform"

[ports.in]
# buffer = back-pressure: the producer's caller parks when 500 are in flight.
doc = { schema = "Document@1", buffer = 500 }

[ports.out]
labeled = { schema = "LabeledDoc@1" }

[effects]
http = { allow = ["api.openai.com"], methods = ["POST"] }

[contract]
pure_core    = "MyApp.Nodes.Classify.build_request/2"
effect_shell = "MyApp.Nodes.Classify.execute/2"
timeout_ms   = 30000
retry        = { strategy = "exponential", max = 3, on = ["timeout"], base_ms = 200 }

[rate]
# Hand at most 60 docs/min to the classifier, regardless of upstream burst.
allowed     = 60
interval_ms = 60000
```

Wire it ingest → classify → route → persist, branching on the label:

```toml
# networks/triage.bloccs
[network]
id      = "triage"
version = "0.1.0"

[nodes]
ingest  = { use = "../nodes/ingest.bloccs" }
classify = { use = "../nodes/classify.bloccs" }
route   = { use = "../nodes/route.bloccs" }    # kind = "router"
persist = { use = "../nodes/persist.bloccs" }
review  = { use = "../nodes/review.bloccs" }

[[edges]]
from = "ingest.doc"
to   = "classify.doc"

[[edges]]
from = "classify.labeled"
to   = "route.labeled"

[[edges]]
from = "route.auto"      # router emits on `auto` for high-confidence labels
to   = "persist.doc"

[[edges]]
from = "route.uncertain" # and on `uncertain` for the rest
to   = "review.doc"

[deploy]
concurrency = { classify = 8 }   # 8 in-flight model calls under the rate cap
```

`build_request/2` (pure core) turns a `Document@1` into the request payload;
`execute/2` (effect shell) makes the `http` call and returns `{:emit, ...}` with a
`LabeledDoc@1`. The router node's shell returns the out-port (`auto` /
`uncertain`) to branch on — conditional logic lives in node code, never in edge
predicates.

## Multi-stage RAG

`retrieve → rank → synthesize → verify`, where the value is the *flow*: each stage
is a typed node with its own effect scope, and the edges are schema-checked end to
end so a shape change in one stage fails validation instead of surfacing at 3am.

```toml
# networks/rag.bloccs
[network]
id      = "rag"
version = "0.1.0"

[nodes]
retrieve  = { use = "../nodes/retrieve.bloccs" }   # http -> vector store
rank      = { use = "../nodes/rank.bloccs" }       # pure, or http -> reranker
synthesize = { use = "../nodes/synthesize.bloccs" } # http -> model
verify    = { use = "../nodes/verify.bloccs" }     # http -> model, kind = "router"

[[edges]]
from = "retrieve.hits"
to   = "rank.hits"

[[edges]]
from = "rank.ranked"
to   = "synthesize.ranked"

[[edges]]
from = "synthesize.draft"
to   = "verify.draft"

[[edges]]
from = "verify.passed"     # verify is a router: passed vs needs_retrieval
to   = "answer.draft"

[[edges]]
from = "verify.needs_more"
to   = "retrieve.query"    # NOTE: this is a cycle — see below
```

Each node declares exactly the host it needs (`retrieve` the vector store,
`synthesize`/`verify` the model), so a security reviewer reads one `[effects]`
block per stage to know what it can reach. Put `[rate]` on the model-calling nodes
to stay under provider limits, and `buffer` on their in-ports for back-pressure,
exactly as in the classification recipe.

> **Cycles are roadmap.** A verify→retrieve feedback loop is a cyclic graph;
> bloccs is DAG-only today (the validator rejects cycles). Model the retry as a
> bounded fan-out for now — `verify` emits low-confidence drafts to a separate
> `escalate` sink — until cyclic networks land.

## Entering a network from a web request

A network is asynchronous by default. To use one for request-bound logic (a
LiveView or controller that needs an answer back), use `Bloccs.call/4`: the
pipeline stays async, only the caller waits.

```elixir
case Bloccs.call(:checkout, :request, %{"items" => items}) do
  {:ok, %{"total" => total}} -> # the reply node emitted this
  {:error, %Bloccs.EffectError{node: node}} -> # a stage failed; comes back as data, not a hang
end
```

The terminal node opts in with `reply = true` and emits the response on an
out-port. Correlation reuses the per-message trace id, so an un-awaited push costs
nothing. See the [request/response guide](request-response.md).

## Durability: Oban at the edges

bloccs is in-memory: when a node crashes its supervisor restarts it, but in-flight
messages are not persisted. For work that must not be lost (the canonical example
is an outbound send that must be exactly-once and survive a restart), keep the
durable step in Oban and let bloccs own the dataflow around it. They compose two
ways:

- **bloccs → Oban**: an effect shell enqueues an Oban job at the point durability
  starts mattering, and returns. The job carries the idempotency key.
- **Oban → bloccs**: an Oban worker pushes a message into a network with
  `Bloccs.cast/4` (or `call/4` if it needs the result), so a durable trigger feeds
  a typed graph.

Reach for Oban (not bloccs) when the unit of work is a *job* that must survive
restarts, be scheduled, or be uniquely deduped across time. Reach for bloccs when
the unit of work is a *message flowing through a graph*. The
[comparison guide](comparison.md) maps this out against Oban, Temporal, Reactor,
and `boundary`.
