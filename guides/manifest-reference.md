# Manifest reference

Every field of the two manifest formats, with types and whether it's required.
Manifests are TOML. For what the words mean, see [Core concepts](concepts.md).

- [Node manifest](#node-manifest) — one node per `.bloccs` file
- [Network manifest](#network-manifest) — topology

---

## Node manifest

### `[node]` — required

| key | type | required | meaning |
|---|---|---|---|
| `id` | string | ✓ | node identifier |
| `version` | string | ✓ | semver of this node |
| `kind` | `"source"` \| `"transform"` \| `"router"` \| `"sink"` | ✓ | role in the graph |

```toml
[node]
id      = "enrich"
version = "0.1.0"
kind    = "transform"
```

### `[doc]` — optional

Human-facing documentation. Both keys optional.

| key | type | meaning |
|---|---|---|
| `intent` | string | what the node is for |
| `owner` | string | team/person responsible |

### `[ports.in]` / `[ports.out]`

A table of named ports. Each value is an inline table:

| key | type | required | meaning |
|---|---|---|---|
| `schema` | string `"Name@N"` | ✓ | the message schema on this port |
| `buffer` | positive integer | — | in-ports only: producer mailbox bound (back-pressure). Ignored on out-ports. |

```toml
[ports.in]
event = { schema = "RawEvent@1", buffer = 1000 }

[ports.out]
enriched = { schema = "EnrichedEvent@1" }
failed   = { schema = "FailedEvent@1" }
```

> The schema strings must be registered via `Bloccs.Schema.register/2` at app
> start. Edges between ports are checked for matching schemas at validation time.

### `[effects]` — optional

Declared capabilities. Omit the block (or an axis) to deny that axis entirely.
An undeclared axis is refused at runtime; a declared one is allowlist-enforced.

| axis | type | meaning |
|---|---|---|
| `http` | `{ allow = [host, …], methods = [method, …] }` | outbound HTTP, restricted to those hosts + methods (re-checked on every redirect hop) |
| `db` | `{ allow = [scope, …] }` | DB ops, each scope a `"table:action"` string |
| `time` | `"wall_clock"` \| `"none"` | clock access |
| `random` | `"none"` \| `"pseudo"` \| `"crypto"` | randomness source (`"crypto"` draws from `:crypto.strong_rand_bytes/1`) |

> Misdeclarations are **parse errors**, not silent denials: an unknown axis
> (e.g. a typo'd `htttp`) or a misshapen declaration (`allow` not a list of
> strings, a non-string `time`/`random`) fails `mix bloccs.validate` rather
> than being treated as "nothing declared".

```toml
[effects]
http = { allow = ["enrichment.local"], methods = ["GET"] }
db   = { allow = ["events:insert"] }
time = "wall_clock"
```

### `[contract]` — required

| key | type | required | meaning |
|---|---|---|---|
| `pure_core` | string `"Mod.fun/arity"` | ✓ | pure-core function ref; must exist with that arity |
| `effect_shell` | string `"Mod.fun/arity"` | ✓ | effect-shell function ref; must exist with that arity |
| `timeout_ms` | positive integer | — | bounds each attempt; overrun fails the message with `:timeout` (retriable) |
| `idempotency` | `{ key = "field" }` | — | dedup repeat deliveries by that payload field (atomic in-flight reservation) |
| `retry` | inline table (below) | — | retry policy |

**`retry` table:**

| key | type | required | meaning |
|---|---|---|---|
| `strategy` | `"constant"` \| `"linear"` \| `"exponential"` | ✓ | back-off curve |
| `max` | non-negative integer | ✓ | max attempts |
| `on` | list of strings | ✓ | failure reasons that are retriable (e.g. `["timeout"]`) |
| `base_ms` | positive integer | — | base delay for the back-off |

Permanent failures (schema mismatch, capability denial) are **never** retried,
regardless of `on`.

```toml
[contract]
pure_core    = "MyApp.Nodes.Enrich.transform/2"
effect_shell = "MyApp.Nodes.Enrich.execute/2"
timeout_ms   = 3000
idempotency  = { key = "id" }
retry        = { strategy = "exponential", max = 2, on = ["timeout"], base_ms = 50 }
```

### `[batch]` — optional

Present only on **aggregate** nodes. When set, the node processes messages in
batches via Broadway batchers instead of one at a time: its `pure_core` receives
the **list** of payloads in the batch (not a single payload) and reduces them,
and its `effect_shell` emits the aggregate result (one emit, a split, or a drop —
like any node). The batch flushes when it reaches `size` messages or after
`timeout_ms` of idle, whichever is first, so a partial batch is never stranded.

| key | type | default | meaning |
|---|---|---|---|
| `size` | positive integer | 100 | count window — flush after this many messages |
| `timeout_ms` | positive integer | 1000 | time window — flush a partial batch after this idle period |

At least one of `size` / `timeout_ms` must be set. A `[batch]` node may **not**
also declare `[contract].retry`, `idempotency`, or `timeout_ms` — the batch path
is at-least-once and does not run those per-message policies yet (the validator
rejects the combination).

```toml
[batch]
size       = 100
timeout_ms = 5000
```

### `[join]` — optional

Present only on **join** nodes. A join node has **two or more** in-ports
carrying distinct schemas; arrivals are correlated by the value of the `on`
field (present in every input payload). When all in-ports have produced a
payload for the same key, the node's `pure_core` receives the map
`%{port => payload}` and emits the joined result. (This is the one case where a
node may declare more than one in-port — each compiles to its own pipeline.)

| key | type | default | meaning |
|---|---|---|---|
| `on` | string (field name) | — (required) | correlation key — a *field name* present in every input payload (not a predicate) |
| `timeout_ms` | positive integer | — | how long to hold a partial match before giving up |
| `deadletter` | string (out-port name) | — | a partial match that times out is emitted there as an `%{key, present, payloads}` envelope; without it, a timeout drops with a `[:bloccs, :join, :timeout]` event |

A `[join]` node may **not** also be a `[batch]` node, nor declare
`[contract].retry` / `idempotency` / `timeout_ms` (the join path is
at-least-once and does not run those per-message policies yet).

```toml
[ports.in]
left  = { schema = "Order@1" }
right = { schema = "Payment@1" }

[ports.out]
joined     = { schema = "Reconciled@1" }
deadletter = { schema = "Unmatched@1" }

[join]
on         = "order_id"
timeout_ms = 30000
deadletter = "deadletter"
```

### `[rate]` — optional

Throttle: cap how fast the node's producer delivers messages downstream, using
Broadway's built-in producer rate limiting.

| key | type | meaning |
|---|---|---|
| `allowed` | positive integer | messages allowed per interval |
| `interval_ms` | positive integer | the interval window, in ms |

```toml
[rate]
allowed     = 100
interval_ms = 1000
```

### `[delay]` — optional

Delay: hold every message for `ms` before it enters the node (the producer
time-shifts delivery — the push is acked immediately, it does not back-pressure).

```toml
[delay]
ms = 5000
```

`[rate]` and `[delay]` are not supported on a `[join]` node. **Debounce** (collapse
a burst, keep the last) is not a separate block — model it as a time-windowed
`[batch]` whose `pure_core` keeps the last payload.

### `[observability]` — optional

A free-form table captured onto the node (`metrics`, `traces`, …); telemetry is
emitted on every span regardless. Stored as-is for downstream tooling.

```toml
[observability]
metrics = ["duration_ms"]
traces  = "auto"
```

---

## Network manifest

A file is parsed as a network (not a node) when it has a top-level `[network]`
table.

### `[network]` — required

| key | type | required | meaning |
|---|---|---|---|
| `id` | string | ✓ | network identifier |
| `version` | string | ✓ | semver |
| `runtime` | string | — | target runtime; defaults to `"beam"` |

### `[nodes]` — required

A table mapping a **local id** to an instantiation. Each value is an inline table
with a `use` path pointing at a node manifest — *or another network manifest*, in
which case it is flattened in as a subgraph (namespaced ids like `pipe.up`).

| key | type | required | meaning |
|---|---|---|---|
| `use` | string (path) | ✓ | node or network manifest to instantiate |
| `config` | inline table | — | per-instance config overlay for parameterized nodes |

```toml
[nodes]
ingest = { use = "../nodes/ingest.bloccs" }
enrich = { use = "../nodes/enrich.bloccs" }
```

### `[[edges]]` — required

An array of tables. Each edge wires one out-port to one **or more** in-ports.
Endpoints are `"node.port"` strings.

| key | type | required | meaning |
|---|---|---|---|
| `from` | string `"node.port"` | ✓ | source out-port |
| `to` | string \| list of strings | ✓ | one or more destination in-ports (a list fans out) |

```toml
[[edges]]
from = "ingest.event"
to   = "enrich.event"

[[edges]]
from = "route.known"
to   = ["persist.event", "notify.event"]   # fan-out

[[edges]]
from = "left.out"
to   = "collect.in"
[[edges]]
from = "right.out"
to   = "collect.in"                          # fan-in (merge): both feed collect.in
```

The validator checks both endpoints exist, schemas match end-to-end, and the
graph is acyclic. Several edges may target one in-port (fan-in / merge) — that
port's producer receives all of them, interleaved and unordered.

### `[expose]` — optional

Promotes internal ports to the network's public ports (and makes it usable as a
subgraph). Two tables, `in` and `out`, mapping a public name to an internal
`"node.port"`.

```toml
[expose]
in  = { webhook = "ingest.received" }
out = { stored  = "persist.stored",
        dead    = "deadletter.recorded" }
```

`mix bloccs.run --port <name>` and the default message intake use these names.

### `[supervision]` — optional

Supervisor config for the generated tree. Defaults: `one_for_one`, 3, 5.

| key | type | meaning |
|---|---|---|
| `strategy` | `"one_for_one"` \| `"one_for_all"` \| `"rest_for_one"` | restart strategy |
| `max_restarts` | non-negative integer | restart intensity |
| `max_seconds` | positive integer | restart window |

### `[deploy]` — optional

| key | type | meaning |
|---|---|---|
| `concurrency` | table `{ node = N, … }` | per-node Broadway processor concurrency |
| `placement` | string | placement hint (captured; `"default"` today) |

```toml
[deploy]
concurrency = { enrich = 4, persist = 1 }
placement   = "default"
```
