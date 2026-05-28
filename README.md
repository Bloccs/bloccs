# bloccs

A typed declarative IR for **Agentic Computation Graphs (ACGs)** that compiles
to a Broadway supervision tree on the BEAM.

> "Microsoft's declarative workflows have `GotoAction`. That's not declarative —
> that's BASIC in YAML." Bloccs is the answer: a real graph, typed effects, and
> a supervisor tree underneath.

## Status

**v0.1 — pre-release.** The OSS core is under active development. Not yet on
Hex. See the parent monorepo `Bloccs/bloccs_cell` for the full design context
(research, ADRs, commercialization plan).

## What it is

You write your workflow as two kinds of TOML manifests:

- **Node manifests** (`.bloccs`) — one per file. Declares the node's input and
  output ports with versioned schemas, the effects it's allowed to perform
  (HTTP / DB / Time / Random), the pure-core and effect-shell function refs,
  retry/timeout/idempotency policy.
- **Network manifests** — declares topology: which nodes are wired to which,
  how supervision is structured, concurrency per node.

`bloccs compile` reads these and emits a Broadway-based supervision tree:
one stage per node, a router for edges, a producer for each inbound port.

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
random = "none"

[contract]
pure_core    = "Bloccs.Payments.ChargeCustomer.transform/2"
effect_shell = "Bloccs.Payments.ChargeCustomer.execute/2"
retry        = { strategy = "exponential", max = 3, on = ["network", "stripe_5xx"] }
timeout_ms   = 5000
```

The node's implementation is split: a pure-core function (no IO, no clock,
no randomness) and an effect-shell that touches the world. The shell can only
use effects declared in `[effects]` — undeclared calls are refused at runtime
by the capability struct, and the `use Bloccs.Node` macro warns at compile
time when the AST shows undeclared usage.

## v0.1 surface

- `mix bloccs.new <name>` — scaffold a new project
- `mix bloccs.validate <file>` — schema/contract checks on a node or network
- `mix bloccs.compile <network>` — emit the Broadway supervision tree
- `mix bloccs.run <network>` — start the tree and feed a message
- `mix bloccs.coverage <network>` — port/edge coverage stub

## Out of scope for v0.1

Phoenix LiveView canvas (v0.3+) · MCP server (v0.2) · `.bloccs-trace` (v0.4+) ·
Pro / encrypted packages (private repo, post-v0.1) · polyglot `pure_core` ·
subgraph composition · cyclic networks.

## License

MIT. Pro extensions ship later in a separate private repo (modeled on
Oban Pro).
