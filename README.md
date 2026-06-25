<p align="center">
  <a href="https://bloccs.io">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/bloccs-logo-dark.png">
      <img alt="Bloccs" src="assets/bloccs-logo-light.png" width="360">
    </picture>
  </a>
</p>

<p align="center"><strong>Typed, supervised dataflow on the BEAM.</strong></p>

<p align="center">
  <a href="https://hex.pm/packages/bloccs"><img alt="Hex Version" src="https://img.shields.io/hexpm/v/bloccs.svg"></a>
  <a href="https://hexdocs.pm/bloccs"><img alt="Hex Docs" src="https://img.shields.io/badge/hex-docs-blue.svg"></a>
  <a href="https://github.com/Bloccs/bloccs/blob/main/LICENSE"><img alt="Apache 2 License" src="https://img.shields.io/hexpm/l/bloccs.svg"></a>
</p>

You describe a graph of processing stages as TOML; bloccs type-checks the
wiring, enforces what each stage is allowed to do, and compiles it to a
Broadway/GenStage supervision tree.

> **Pre-1.0 — moving fast.** The public API and the manifest format may still
> change between minor releases, so pin a version and check the
> [CHANGELOG](CHANGELOG.md) before you upgrade. The runtime is built for
> production within its lane: supervised, back-pressured, capability-checked, with
> retry / timeout / idempotency / telemetry wired in. The one thing it leaves out
> by design is durability — in-flight messages live in memory, so put Oban or a
> broker at the edges for work that must survive restarts.

<p align="center">
  <img width="880" alt="The events example — a webhook processor: ingest → validate → enrich → route, fanning out to persist and notify, dead-lettering unknown event types" src="assets/events-hero.png">
</p>

## Why bloccs?

Plenty of backend work is a *graph of stages*: ingest → validate → enrich →
branch → persist/notify. On the BEAM you'd build that today by hand-wiring a few
Broadway pipelines and a supervisor. That works, but nothing checks it:

- the **connections between stages are untyped** — stage A emits a map, stage B
  expects a different shape, and you find out in production;
- the **side effects are unconstrained** — any stage can call any host or table;
  nothing says `enrich` is only allowed to `GET` the enrichment service;
- **retry / timeout / idempotency / back-pressure** get re-implemented, slightly
  differently, in every pipeline;
- the **topology lives in your head** (and a supervisor module), not in a
  reviewable artifact;
- and once an **LLM is writing the pipelines**, you're auditing sprawling
  generated glue line by line — the shape of the system buried in code, with a
  wrong wiring or an unscoped side effect easy to miss in the diff.

bloccs makes the graph a declared, checked thing. You write the topology and the
per-stage contracts as TOML; bloccs rejects a graph whose edges don't type-match
*before it runs*, refuses an effect a node didn't declare, and generates the
Broadway supervision tree — as real, debuggable `.ex` source — with the retry /
timeout / idempotency / back-pressure already wired in. The artifact you review
is the manifest, not the generated glue — which is what keeps a human in control
when an LLM is doing the typing (see [Legible to humans and
LLMs](#legible-to-humans-and-llms)).

> **Why not just write Elixir, or use Broadway directly?** You can — and for a
> *single* pipeline you should (see [How it compares](#how-it-compares)). bloccs
> earns its keep once you have a *graph* and want the edges (schemas), the
> effects (capabilities), and the per-node policy declared and machine-checked
> rather than maintained by hand. The next section shows the two checks that
> aren't possible with plain Broadway.

## Features

What you get that hand-wired Broadway pipelines don't:

- **Typed edges** — every connection carries a versioned schema (`Name@N`); a
  graph whose ports don't match is rejected at validation time, before it runs.
- **Capability-scoped effects** — a node may only touch the world (HTTP / DB /
  Time / Random) through effects it declared; an undeclared host or axis is
  refused at runtime and warned at compile time.
- **Reviewable output** — the compiler emits the Broadway/OTP supervision tree as
  real, debuggable `.ex` source you can read and `git diff` in a PR.
- **The topology is a declared artifact** — a TOML manifest, not a supervisor
  module you reconstruct in your head.

Wired into every generated node:

- **Retry** with backoff (constant / linear / exponential), matched against the
  failure reason; permanent failures are never retried.
- **Timeouts** that bound each node in a task.
- **Idempotency** keys reserved atomically in-flight.
- **Back-pressure** via bounded buffers instead of dropping.
- **Observability** — `:telemetry` spans and events for every node and edge,
  plus per-message lineage so a message can be tracked across the graph.
- **Flow primitives** — transform, filter, split, route, merge,
  aggregate/window (`[batch]`), join, throttle/delay — and subgraph composition.
- **Request/response** — `Bloccs.call/4` / `cast/4` get a computed result (or a
  typed error) back from a `reply = true` node, without making the pipeline
  synchronous. Lets a web layer use a network for request-bound business logic,
  not just fire-and-forget. See the [request/response guide](guides/request-response.md).

A companion package, [bloccs_web](https://github.com/Bloccs/bloccs_web), is a
self-hosted dashboard that renders the topology and these telemetry signals live.

## Requirements

- Elixir `~> 1.18`
- `broadway ~> 1.1` and `gen_stage ~> 1.2` (pulled in automatically)

## Install

```elixir
def deps do
  [{:bloccs, "~> 0.9"}]
end
```

Then `mix deps.get`. The effect adapters are bring-your-own and opt-in — add
`{:req, "~> 0.5"}` for the real HTTP backend and point the DB backend at your Ecto
repo only if you use them (see
[`guides/effect-adapters.md`](guides/effect-adapters.md)).

## Quickstart

With the dep in place, the loop is **validate → compile → run** over a network
manifest. Point the tasks at a `.bloccs` network — write one (see
[`guides/concepts.md`](guides/concepts.md) and the [manifest
reference](guides/manifest-reference.md)) or copy `networks/` + `nodes/` from
[`examples/tour`](https://github.com/Bloccs/bloccs/tree/main/examples/tour):

```bash
mix bloccs.validate networks/hello.bloccs
mix bloccs.compile  networks/hello.bloccs
mix bloccs.run      networks/hello.bloccs --message '{"name": "ada"}'
```

`mix bloccs.compile` emits real, debuggable `.ex` source under
`_build/<env>/bloccs_generated/<network>/` — diff it in a PR. For a step-by-step
walkthrough that writes a node by hand, see
[`guides/getting-started.md`](guides/getting-started.md).

### Start a new project from scratch

To begin from a runnable example instead, install the `bloccs.new` generator as a
Mix archive and scaffold a project — it wires the dep, a sample node and its
schemas, and a one-node network:

```bash
mix archive.install hex bloccs   # makes `mix bloccs.new` available
mix bloccs.new my_flow
cd my_flow
mix deps.get
mix bloccs.run networks/hello.bloccs --message '{"name": "ada"}'
```

### Add bloccs to an existing app

Already have a Mix project? Add the dep, then generate nodes and a network in
place instead of scaffolding a new one:

```bash
mix bloccs.gen.node ingest --kind source   # nodes/ingest.bloccs + lib/nodes/ingest.ex
mix bloccs.gen.node enrich                  # a transform node
mix bloccs.gen.network pipeline --node ingest --node enrich
```

`gen.node` writes a manifest (`nodes/<name>.bloccs`) and its implementation
(`lib/nodes/<name>.ex` — a pure core + effect shell, skeletoned by `--kind`);
`gen.network` writes the topology. Register the port schemas the nodes reference,
fill in the `[[edges]]`, then `mix bloccs.validate networks/pipeline.bloccs`.

## Typed edges and scoped effects

This is the part you can't get from hand-wired Elixir. Both examples below are
real output from the tour example (`examples/tour`).

**1. Mismatched edges are rejected at validation time.**
`examples/tour/networks/pipeline_mismatch.bloccs` wires an out-port carrying
`WordRequest@1` into an in-port that expects `Definition@1`. Validate it:

```bash
$ cd examples/tour
$ mix bloccs.validate networks/pipeline_mismatch.bloccs
✗ networks/pipeline_mismatch.bloccs
  - [[edges]] (networks/pipeline_mismatch.bloccs): edge accept.word → define.word
    schema mismatch: accept.word=WordRequest@1 but define.word=Definition@1
```

The network never starts. Plain Broadway has no contract between pipelines —
this mismatch would surface as a `FunctionClauseError` (or worse, silently wrong
data) at 3am.

**2. Undeclared side effects are refused.** A node may only touch the world
through effects it declared in `[effects]`. `define` declares HTTP to exactly
one host:

```toml
[effects]
http = { allow = ["dictionary.local"], methods = ["GET"] }
```

Call anything else and the capability struct refuses it at runtime:

```
# a host the node didn't allow:
bloccs effect denied: :http — host of http://evil.example/leak
                              not in declared allowlist ["dictionary.local"]

# an effect axis the node never declared at all:
bloccs effect denied: :http — axis not declared
```

And `use Bloccs.Node` warns you at *compile* time the moment the effect shell
reaches for an undeclared axis:

```
warning: bloccs: effect :http used in effect_shell but not declared in
         [effects]. Declared: [].
```

The allowlist holds across redirects too: the real HTTP backend re-checks
every 3xx hop's host and method before following it, so a declared host that
redirects to an undeclared one is denied, not followed. And a *misdeclared*
`[effects]` block — a typo'd axis, a non-list allowlist — is a validation
error, never silently treated as "nothing declared".

Typed edges and capability-scoped effects are the two guarantees that make a
bloccs graph safer than the same graph hand-wired.

## The manifests

Two kinds of TOML manifest:

- **Node manifests** (`.bloccs`, one node per file) — the node's input/output
  ports with versioned schemas, the effects it's allowed to perform (HTTP / DB /
  Time / Random), the pure-core and effect-shell function refs, and retry /
  timeout / idempotency / buffer policy.
- **Network manifests** — topology: which nodes wire to which, supervision
  structure, concurrency per node, and which ports are exposed.

```toml
# nodes/enrich.bloccs
[node]
id = "enrich"
version = "0.1.0"
kind = "transform"

[ports.in]
valid = { schema = "RawEvent@1" }

[ports.out]
enriched = { schema = "EnrichedEvent@1" }

[effects]
http = { allow = ["enrichment.local"], methods = ["GET"] }

[contract]
pure_core    = "MyApp.Nodes.Enrich.transform/2"
effect_shell = "MyApp.Nodes.Enrich.execute/2"
retry        = { strategy = "exponential", max = 2, on = ["timeout"], base_ms = 50 }
timeout_ms   = 3000
idempotency  = { key = "id" }
```

Each node's implementation is split in two: a **pure core** (no IO, no clock, no
randomness — easy to test, deterministic) and an **effect shell** that touches
the world, and only through declared effects.

## How it works

What the compiler emits from those manifests, and how each node behaves
once it's running.

### Flow primitives

A node's behavior is its ports + contract, not a fixed "type". From those, the
common dataflow shapes fall out — most are just what the effect shell returns,
the rest a small manifest block:

| primitive | how |
|---|---|
| **transform** | `pure_core` computes; shell emits one message |
| **filter** | shell returns `:drop` — consume, emit nothing |
| **split / fan-out** | shell returns `{:emit, [{port, payload}, …]}`, or one out-port wired to many in-ports |
| **route / branch** | a `router` shell picks which out-port to emit on |
| **merge (fan-in)** | several edges into one in-port |
| **aggregate / window** | `[batch]` — `pure_core` reduces the batch (count or time window) |
| **join** | `[join]` — correlate two+ typed in-ports by a key |
| **throttle / delay** | `[rate]` / `[delay]` |

<p align="center">
  <img width="720" alt="The bloccs notation: hexagon glyphs for each primitive — node, source, sink, split, merge, filter, batch, join, throttle, delay, subgraph — where a node that declares an effect carries a badge" src="assets/bloccs-notation.png">
</p>

Conditional logic lives in node code (a returned port, a `:drop`), never in edge
predicates — which keeps the topology declarative and machine-checkable. The
[primitives reference](guides/primitives.md) catalogues each one (glyph, what it
does, how to declare it); see also [`guides/concepts.md`](guides/concepts.md) and
the [manifest reference](guides/manifest-reference.md).

### The generated runtime

<p align="center">
  <img width="900" alt="From file to running system: the .bloccs manifest is the source of truth, the diagram is a view of it, and the Broadway/OTP supervision tree is the compiled output" src="assets/concept-manifest-to-tree.png">
</p>

`mix bloccs.compile` reads the manifests and emits a Broadway-based supervision
tree — one stage per node, a router for edges, a producer for each inbound port.
Every declared contract is wired into that runtime, not just parsed:

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
  silently dropped — including a scheduled retry whose producer disappeared
  before it fired (`[:bloccs, :producer, :enqueue_lost]`, which also releases
  the message's idempotency reservation).
- **Subgraph composition** — a `[nodes]` entry may `use` a *network* manifest;
  the parser flattens it into namespaced leaf nodes at parse time.

### Request/response

A network is asynchronous by default — push in, side effects out, nothing back.
`Bloccs.call/4` (blocking) and `Bloccs.cast/4` (async) add request/response on
top, so a web layer can use a network for request-bound logic, not just
fire-and-forget. The pipeline itself stays async — only the caller waits.

A terminal node opts in with `reply = true` and emits the response on an out-port:

```elixir
{:ok, %{"total" => 42}} = Bloccs.call(:checkout, :request, %{"items" => [...]})

# failures come back as data, not as a hang:
{:error, %Bloccs.EffectError{node: :price, phase: :execute}} =
  Bloccs.call(:checkout, :request, bad_payload)
```

Correlation reuses the per-message `trace_id` (`Bloccs.Lineage`): `call/4`
registers it with `Bloccs.Collector` before pushing, the reply (or a terminal
error) is matched back to the waiting caller, and an unregistered trace costs
nothing. See the [request/response guide](guides/request-response.md).

### Effects: mock by default, real adapters opt-in

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
[`examples/real_backend`](https://github.com/Bloccs/bloccs/tree/main/examples/real_backend).

### CLI (Mix tasks)

- `mix bloccs.new <name>` — scaffold a new project
- `mix bloccs.gen.node <name> [--kind <kind>]` — add a node (manifest + impl) to an existing app
- `mix bloccs.gen.network <name> [--node <node>]...` — add a network manifest to an existing app
- `mix bloccs.validate <file>` — schema / contract / DAG checks on a node or network
- `mix bloccs.compile <network>` — emit the Broadway supervision tree
- `mix bloccs.run <network> --message <json> [--trace <out>]` — start the tree,
  feed a message, optionally record a `.bloccs-trace`
- `mix bloccs.coverage <network> [--message <json> | --trace <file>]` — real
  structural coverage (every in-port, out-port, and edge) from a recorded run

### Legible to humans and LLMs

A bloccs network is a small declarative artifact: the topology is a TOML file,
and each node is a manifest plus two functions (a pure core and an effect
shell). The thing you *review* stays small even when an assistant writes most of
the implementation.

- **You review the graph, not the glue.** A change to the flow is a diff to a
  `.bloccs` file — which ports moved, which edge appeared — not a re-read of
  regenerated supervisor and pipeline code. The generated `.ex` is there to
  inspect when you want it, but the manifest is what you read.
- **A change's blast radius is one node.** Each node is a bounded unit: a
  manifest, a `pure_core`, an effect shell. An assistant can add or alter a node
  without reaching into the rest of the tree.
- **The boundaries are machine-checked, so you don't have to take the code's
  word for it.** A mis-wired edge is rejected at validation time; an undeclared
  host or table is refused. An LLM can move fast and still cannot connect
  mismatched stages or smuggle in an unscoped side effect — the compiler stops
  it before it runs.

So you can hand the repetitive parts to an assistant and stay in control of the
*shape* of the system, instead of drowning in generated code you have to audit
line by line.

> **Pointing an assistant at bloccs?**
> [`llms.txt`](https://github.com/Bloccs/bloccs/blob/main/llms.txt) is a
> machine-readable summary — what bloccs is (and isn't), when to use it, when not
> to, and links to every guide. [`guides/recipes.md`](guides/recipes.md) has
> copy-pasteable end-to-end manifests for the common shapes.

## Examples

A graded ladder under [`examples/`](https://github.com/Bloccs/bloccs/tree/main/examples) — see [`examples/README.md`](https://github.com/Bloccs/bloccs/blob/main/examples/README.md):

- [`examples/tour`](https://github.com/Bloccs/bloccs/tree/main/examples/tour) — core concepts one rung at a time
  (`mix tour.hello` · `mix tour.pipeline` · `mix tour.branching`), mock effects,
  zero setup.
- [`examples/events`](https://github.com/Bloccs/bloccs/tree/main/examples/events) — the flagship: a webhook/event processor
  showing typed edges, HTTP + DB effects, retry, timeout, idempotency, branching,
  fan-out, and coverage (the `events.demo` task).
- [`examples/real_backend`](https://github.com/Bloccs/bloccs/tree/main/examples/real_backend) — the same shape against real
  HTTP (Req) + SQLite (Ecto) (`mix price_watch.demo`).

## How it compares

bloccs **generates** Broadway — it isn't a competitor to it. Reach for Broadway
directly when you have a single pipeline; reach for bloccs when you have a *graph*
of typed stages and want the edges (schemas), effects (capabilities), and
per-node policy (retry / timeout / idempotency / back-pressure) declared and
checked, with the topology as a reviewable artifact. It is **not** durable — for
work that must survive restarts, put Oban or a broker at the edges. Full
comparison against Broadway, Oban, Reactor, Temporal, LangGraph, and plain
GenServers: [`guides/comparison.md`](guides/comparison.md).

### Prior art

Flow-based programming on the BEAM isn't new. Anton Mishchuk's lineage —
[Flowex](https://github.com/antonmi/flowex) → [ALF](https://github.com/antonmi/ALF)
→ [Strom](https://github.com/antonmi/strom) / [Kraken](https://github.com/antonmi/kraken)
— spent years establishing that the actor model and GenStage make the BEAM a natural
home for FBP, and Kraken reached the same "graph-as-data + declarative adapters" idea
bloccs builds on. bloccs owes that groundwork.

The difference is the guarantees, not the shape:

- **Compile-time contracts.** Edges are schema-checked and effects are
  capability-checked *before* the network runs; that lineage validates (or trusts) at
  runtime.
- **Reviewable output.** bloccs emits the Broadway supervision tree as real `.ex`
  source you can read and diff. ALF interprets a runtime DSL; Kraken compiles JSON to
  modules at runtime. A bloccs network is something you can `git diff`.
- **A settled substrate.** bloccs commits to Broadway; the lineage moved between
  GenStage and plain streams.

**What bloccs is _not_:** a runtime DSL (the manifest is compiled ahead of time, not
interpreted), a data-ingestion pipeline (that's Broadway — which bloccs generates), a
visual builder (the file is canonical; a canvas is a view), or durable (put Oban or a
broker at the edges for work that must survive restarts).

## License

Released under the [Apache License 2.0](LICENSE).
