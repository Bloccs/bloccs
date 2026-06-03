# Core concepts

bloccs is a typed, declarative IR for **Agentic Computation Graphs (ACGs)**. You
describe a workflow as TOML manifests; bloccs validates them and compiles them
into a Broadway supervision tree on the BEAM. This page defines the vocabulary —
read it once and the rest of the docs will make sense.

The two artifacts you write are **node manifests** and **network manifests**.
Everything else is something those manifests refer to.

## Manifest

A **manifest** is a TOML file. It is the *source of truth* — not a config file
that decorates code, but the canonical description of the thing. A future canvas
would be a view onto the manifest; the file is always authoritative.

Two kinds:

- A **node manifest** (`.bloccs`, one node per file) describes a single unit of
  work: its ports, the effects it may perform, and the functions that implement
  it.
- A **network manifest** describes topology: which nodes participate, how their
  ports are wired, how they're supervised, and how much concurrency each gets.

## Node

A **node** is the unit of computation — one step in the graph. Each node has a
`kind`:

| kind | meaning |
|---|---|
| `source` | originates messages (an ingress point) |
| `transform` | the common case: takes input, emits output |
| `router` | fans a message out to different ports by content |
| `sink` | terminal; consumes without emitting |

A node manifest pairs with **one implementation module** that does
`use Bloccs.Node, manifest: "path/to/node.bloccs"`. That macro reads and
validates the manifest *at compile time* — a bad manifest is a `CompileError`,
not a runtime surprise.

## Port

A **port** is a named, typed connection point on a node. Ports are directional:

- **In-ports** (`[ports.in]`) receive messages. An in-port may declare a
  `buffer` — the bound on its producer's mailbox (see *back-pressure* below).
- **Out-ports** (`[ports.out]`) emit messages. The effect shell returns
  `{:emit, <out-port>, payload}` to send on one.

Every port references a **schema**.

## Schema

A **schema** is a versioned contract for a message's shape, written `Name@N`
(e.g. `Event@1`). The `@N` is a version: a breaking change to the shape is a new
version (`Event@2`), so old and new can coexist on the wire.

Schemas are registered at application start with `Bloccs.Schema.register/2`:

```elixir
Bloccs.Schema.register("Event@1",
  id: :string,
  type: :string,
  payload: :map
)
```

When two ports are wired by an edge, bloccs checks at validation time that their
schemas match — you cannot connect an `Event@1` out-port to an
`EnrichedEvent@1` in-port.

## Effect

An **effect** is a *declared capability* to touch the outside world — not a
function call you happen to make, but a permission stated up front in
`[effects]`. There are four axes:

| axis | declaration | meaning |
|---|---|---|
| `http` | `{ allow = ["host", …], methods = ["GET", …] }` | outbound HTTP, restricted to the listed hosts + methods |
| `db` | `{ allow = ["table:action", …] }` | DB ops, restricted to the listed `table:action` scopes |
| `time` | `"wall_clock"` or `"none"` | reading the clock |
| `random` | `"none"`, `"pseudo"`, or `"crypto"` | randomness |

The guarantee is **capability-based** and has two layers:

1. **Runtime (load-bearing).** At bind time each *declared* axis becomes a real
   adapter; each *undeclared* axis becomes a `Bloccs.Effects.Denied.Stub` whose
   every method raises `Bloccs.Effects.Denied`. Declared adapters still enforce
   the per-call allowlist (an HTTP call to a host not in `allow` is refused).
2. **Compile-time (ergonomics).** `use Bloccs.Node` walks the effect-shell AST
   and warns when it sees `ctx.effects.X.*` for an `X` you didn't declare — a
   fast "you forgot to declare that effect" signal.

Adapters are swappable (mock by default, real `Req`/`Ecto` behind config) — see
[Effect adapters](effect-adapters.md).

## Pure core and effect shell

Every node's implementation is split in two, by design:

- **pure core** — `pure_core(message, ctx) :: {:ok, intermediate} | {:error, reason}`.
  No IO, no clock, no randomness. Pure validation and computation. Easy to test,
  deterministic.
- **effect shell** — `effect_shell(intermediate, ctx) :: {:emit, port, payload} | {:error, reason}`.
  Receives a `%Bloccs.Context{}` whose `effects` field holds the capability
  struct. This is the only place the world is touched, and only through declared
  effects.

The two are separate functions with separate typespecs, named in the manifest's
`[contract]`. (The names are yours — the examples use `transform`/`execute`.)

## Network

A **network** composes nodes into a graph. Its manifest declares:

- `[nodes]` — each entry instantiates a node by `use`-ing its manifest (or
  another *network* — see *subgraph* below).
- `[[edges]]` — the wires.
- `[expose]` — which internal ports are the network's own public in/out ports.
- `[supervision]` — strategy + restart policy for the generated supervisor.
- `[deploy]` — per-node concurrency and placement.

## Edge

An **edge** wires one out-port to one *or more* in-ports:

```toml
[[edges]]
from = "route.known"
to   = ["persist.event", "notify.event"]   # fan-out
```

Endpoints are `node.port`. The validator checks both endpoints exist, the
schemas match end-to-end, and the resulting graph is **acyclic** (v0.1 is
DAG-only).

## Subgraph

A network can be reused as a node inside a bigger network: a `[nodes]` entry may
`use` a *network* manifest instead of a node manifest. The parser **flattens** it
at parse time into namespaced leaf nodes (dot-separated ids like `pipe.up`), so
the rest of the pipeline only ever sees a flat graph. `[expose]` is what makes a
network presentable as a subgraph — it maps the network's public ports onto its
internal ones.

## Runtime shape

A validated network compiles to **real `.ex` source** under
`_build/<env>/bloccs_generated/<network>/` (debuggable, PR-reviewable — not
in-memory bytecode). At its core:

- a **Broadway pipeline per node** — the processor calls `pure_core` →
  `effect_shell`, then hands emitted messages to the router;
- a **`Bloccs.Producer`** per in-port — a bounded, back-pressuring GenStage
  producer. When a `buffer` fills, the producer *parks the caller* rather than
  dropping the message;
- a **`Bloccs.Router`** — the edge table; `dispatch/4` looks up an out-port's
  targets and pushes to each downstream producer, and notifies any sink
  listeners (used by tests and the trace recorder).

Declared `[contract]` policies are wired in too: **retry** (backed-off
re-enqueue, matched on failure reason), **timeout** (`timeout_ms` bounds each
attempt), **idempotency** (atomic in-flight reservation by key), and
**telemetry** events on every span.

## Trace and coverage

A run can be recorded to a `.bloccs-trace` (`Bloccs.Trace`, fed by telemetry).
`mix bloccs.coverage` reports **structural coverage** — every in-port, out-port,
and edge against the set actually reached — either live (`--message`) or from a
loaded trace (`--trace`). It's the "which parts of my graph did this input
exercise?" view.

---

Next: walk the whole loop end to end in [Getting started](getting-started.md),
or look up an exact field in the [Manifest reference](manifest-reference.md).
