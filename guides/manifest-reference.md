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
id      = "charge_customer"
version = "1.2.0"
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
charge_requested = { schema = "ChargeRequest@1", buffer = 100 }

[ports.out]
charge_completed = { schema = "ChargeCompleted@1" }
charge_failed    = { schema = "ChargeFailed@1" }
```

> The schema strings must be registered via `Bloccs.Schema.register/2` at app
> start. Edges between ports are checked for matching schemas at validation time.

### `[effects]` — optional

Declared capabilities. Omit the block (or an axis) to deny that axis entirely.
An undeclared axis is refused at runtime; a declared one is allowlist-enforced.

| axis | type | meaning |
|---|---|---|
| `http` | `{ allow = [host, …], methods = [method, …] }` | outbound HTTP, restricted to those hosts + methods |
| `db` | `{ allow = [scope, …] }` | DB ops, each scope a `"table:action"` string |
| `time` | `"wall_clock"` \| `"none"` | clock access |
| `random` | `"none"` \| `"pseudo"` \| `"crypto"` | randomness source |

```toml
[effects]
http = { allow = ["api.stripe.com"], methods = ["POST"] }
db   = { allow = ["charges:insert"] }
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
pure_core    = "Payments.Nodes.ChargeCustomer.transform/2"
effect_shell = "Payments.Nodes.ChargeCustomer.execute/2"
timeout_ms   = 5000
idempotency  = { key = "request_id" }
retry        = { strategy = "exponential", max = 3, on = ["timeout"], base_ms = 100 }
```

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
ingest = { use = "../nodes/http_ingest.bloccs" }
charge = { use = "../nodes/charge_customer.bloccs" }
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
from = "ingest.charge_request"
to   = "charge.charge_requested"

[[edges]]
from = "charge.charge_completed"
to   = ["notify_ok.notice", "ledger.event"]   # fan-out
```

The validator checks both endpoints exist, schemas match end-to-end, and the
graph is acyclic.

### `[expose]` — optional

Promotes internal ports to the network's public ports (and makes it usable as a
subgraph). Two tables, `in` and `out`, mapping a public name to an internal
`"node.port"`.

```toml
[expose]
in  = { intake   = "ingest.http_request" }
out = { sent     = "notify_ok.delivered",
        recorded = "ledger.committed" }
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
concurrency = { charge = 2, ledger = 1 }
placement   = "default"
```
