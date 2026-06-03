# bloccs

A typed declarative IR for **Agentic Computation Graphs (ACGs)** that compiles
to a Broadway supervision tree on the BEAM.

> "Microsoft's declarative workflows have `GotoAction`. That's not declarative —
> that's BASIC in YAML." Bloccs is the answer: a real graph, typed effects, and
> a supervisor tree underneath.

## Status

**v0.1 — pre-release.** Not yet on Hex; APIs may change before the first
release. The compiler core is, however, feature-complete for the v0.1 vision:
the full **parse → validate → compile → run** loop works, every declared
runtime contract is honored, the effect adapters are real (behind a config
switch), networks compose, and structural coverage is real. See
[`guides/ARCHITECTURE.md`](guides/ARCHITECTURE.md) for the compile pipeline.

## Quickstart

```bash
# scaffold a starter project (one sample node + a one-node network)
mix bloccs.new my_flow
cd my_flow

# validate, compile to a Broadway supervision tree, then run a message through
mix bloccs.validate networks/hello.bloccs
mix bloccs.compile  networks/hello.bloccs
mix bloccs.run      networks/hello.bloccs --message '{"name": "ada"}'
```

`mix bloccs.compile` emits real, debuggable `.ex` source under
`_build/<env>/bloccs_generated/<network>/`. For a step-by-step walkthrough that
writes a node by hand, see [`guides/getting-started.md`](guides/getting-started.md);
for the vocabulary (node, port, effect, schema, …) see
[`guides/concepts.md`](guides/concepts.md).

## What it is

You write your workflow as two kinds of TOML manifests:

- **Node manifests** (`.bloccs`) — one per file. Declares the node's input and
  output ports with versioned schemas, the effects it's allowed to perform
  (HTTP / DB / Time / Random), the pure-core and effect-shell function refs, and
  retry / timeout / idempotency / buffer policy.
- **Network manifests** — topology: which nodes are wired to which, supervision
  structure, concurrency per node, and which ports are exposed.

`mix bloccs.compile` reads these and emits a Broadway-based supervision tree —
one stage per node, a router for edges, a producer for each inbound port — as
real `.ex` source under `_build/bloccs_generated/<network>/` (debuggable stack
traces, PR-reviewable output).

```toml
# nodes/charge_customer.bloccs
[node]
id = "charge_customer"
version = "1.2.0"
kind = "transform"

[ports.in]
charge_requested = { schema = "ChargeRequest@1", buffer = 100 }

[ports.out]
charge_completed = { schema = "ChargeCompleted@1" }
charge_failed    = { schema = "ChargeFailed@1" }

[effects]
http = { allow = ["api.stripe.com"], methods = ["POST"] }
db   = { allow = ["charges:insert"] }
time = "wall_clock"

[contract]
pure_core    = "Payments.Nodes.ChargeCustomer.transform/2"
effect_shell = "Payments.Nodes.ChargeCustomer.execute/2"
retry        = { strategy = "exponential", max = 3, on = ["timeout"], base_ms = 100 }
timeout_ms   = 5000
idempotency  = { key = "request_id" }
```

The node's implementation is split: a **pure core** (no IO, no clock, no
randomness) and an **effect shell** that touches the world. The shell can only
use effects declared in `[effects]` — undeclared calls are refused at runtime by
the capability struct, and `use Bloccs.Node` warns at compile time when the AST
shows undeclared usage.

## What actually runs

Every declared contract is wired into the generated runtime, not just parsed:

- **Retry** — backed-off re-enqueue (constant / linear / exponential), matched
  against the failure reason; permanent failures (schema mismatch, capability
  denial) are never retried.
- **Timeout** — `timeout_ms` runs the node in a bounded task; overrun fails the
  message with `:timeout` (retriable).
- **Idempotency** — reserves the key in-flight (atomic), so concurrent
  first-deliveries can't both run; released on terminal failure.
- **Back-pressure** — a bounded `buffer` parks the producer's caller until a
  consumer drains, instead of dropping.
- **Observability** — `:telemetry.span([:bloccs, :node], …)` plus `:emit`,
  `:retry`, `:skipped`, and `:dispatch_error` events (see `Bloccs.Telemetry`).
  A failed downstream delivery is surfaced (telemetry + a failed message), never
  silently dropped.
- **Subgraph composition** — a `[nodes]` entry may `use` a *network* manifest;
  the parser flattens it into namespaced leaf nodes at parse time.

## Effects: mock by default, real adapters opt-in

Nodes call a backend-agnostic facade (`Bloccs.Effects.HTTP.post/3`,
`DB.insert/3`, …). The mock backends are the default (tests stay hermetic); the
real ones are selected purely in config, with no node changes:

```elixir
config :bloccs, :effect_backends,
  http: Bloccs.Effects.HTTP.Req,    # real HTTP via Req (add :req to your deps)
  db:   Bloccs.Effects.DB.Ecto      # real SQL via your Ecto repo

config :bloccs, Bloccs.Effects.DB.Ecto, repo: MyApp.Repo, returning: [:id]
```

`bloccs` forces neither `req` nor Ecto on you — both are bring-your-own. Write
your own backend by implementing the `Bloccs.Effects.HTTP` / `DB` behaviour. See
[`guides/effect-adapters.md`](guides/effect-adapters.md). A runnable example
hitting real HTTP + SQLite (zero external services) lives in
[`examples/real_backend`](examples/real_backend).

## CLI (Mix tasks)

- `mix bloccs.new <name>` — scaffold a new project
- `mix bloccs.validate <file>` — schema / contract / DAG checks on a node or network
- `mix bloccs.compile <network>` — emit the Broadway supervision tree
- `mix bloccs.run <network> --message <json> [--trace <out>]` — start the tree,
  feed a message, optionally record a `.bloccs-trace`
- `mix bloccs.coverage <network> [--message <json> | --trace <file>]` — real
  structural coverage (every in-port, out-port, and edge) from a recorded run

## How it compares

bloccs **generates** Broadway — it isn't a competitor to it. Reach for Broadway
directly when you have a single pipeline; reach for bloccs when you have a *graph*
of typed stages and want the edges (schemas), effects (capabilities), and
per-node policy (retry / timeout / idempotency / back-pressure) declared and
checked, with the topology as a reviewable artifact. It is **not** durable — for
work that must survive restarts, put Oban or a broker at the edges. Full
comparison against Broadway, Oban, Reactor, Temporal, LangGraph, and plain
GenServers: [`guides/comparison.md`](guides/comparison.md).

## Out of scope for v0.1

Phoenix LiveView canvas (v0.3+) · MCP server (v0.2) · Pro / encrypted packages
(private repo, post-v0.1) · polyglot `pure_core` · multi-input nodes (one input
port per node in v0.1) · cyclic networks (v0.1 is DAG-only) · escript-packaged
binary · full Dialyzer-level static effect proof · durable persistence.

## License

MIT. Pro extensions ship later in a separate private repo (modeled on Oban Pro).
