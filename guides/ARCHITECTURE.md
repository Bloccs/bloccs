# Architecture

This document describes how the v0.1 OSS library compiles a TOML manifest into a
running Broadway supervision tree. It's the engineering map of the system; for
the vocabulary it uses (node, port, effect, schema, …) read
[Core concepts](concepts.md) first.

## The compile pipeline at a glance

```
            ┌─────────────────────────────────────────────────────────────┐
            │   .bloccs TOML files  (source of truth)                     │
            │                                                             │
            │   nodes/charge_customer.bloccs   networks/payments.bloccs   │
            └────────────┬──────────────────────────────┬─────────────────┘
                         │                              │
                         ▼                              ▼
                ┌──────────────────┐           ┌────────────────────┐
                │ Bloccs.Parser    │           │ Bloccs.Parser      │
                │ .parse_node/1    │           │ .parse_network/1   │
                └────────┬─────────┘           └─────────┬──────────┘
                         │                               │
                         │ %Bloccs.Manifest.Node{}       │ %Bloccs.Manifest.Network{}
                         │                               │   (nodes loaded recursively)
                         ▼                               ▼
                ┌──────────────────────────────────────────────────────┐
                │ Bloccs.Validator                                     │
                │   • edge schemas match across the wire               │
                │   • DAG-only (cycle detection)                       │
                │   • effects ∈ {http,db,time,random}                  │
                │   • pure_core / effect_shell MFAs well-formed        │
                └────────────┬─────────────────────────────────────────┘
                             │ :ok | {:error, [%Issue{}]}
                             ▼
                ┌──────────────────────────────────────────────────────┐
                │ Bloccs.Compiler                                      │
                │   .compile/2  →  source files on disk                │
                │                                                      │
                │   _build/<env>/bloccs_generated/<network>/           │
                │     nodes/<id>.ex      (Broadway pipeline modules)   │
                │     supervisor.ex      (Supervisor + edge table)     │
                └────────────┬─────────────────────────────────────────┘
                             │ Code.require_file/1
                             ▼
                ┌──────────────────────────────────────────────────────┐
                │ <Network>.Supervisor.start_link/1                    │
                │     ├── Broadway pipeline per node                   │
                │     │     ├── Bloccs.Producer                        │
                │     │     │     (registered in Bloccs.Registry)      │
                │     │     ├── Broadway.Topology.Processor            │
                │     │     │     (calls Context.new → pure_core →    │
                │     │     │      effect_shell → Router.dispatch)     │
                │     │     └── Broadway internals                     │
                │     └── (Router registered the edge table at init)   │
                └──────────────────────────────────────────────────────┘
```

Each box maps to a module under `app/bloccs/lib/bloccs/`. Anything emitted by
the compiler is a real `.ex` file you can read, diff, and step through with
the debugger — the "legible IR" thesis applies to compilation output too.

## Module map

| Module | Responsibility | File |
|---|---|---|
| `Bloccs.Schema` | Versioned schema registry (`Name@N`), `:persistent_term`-backed | `lib/bloccs/schema.ex` |
| `Bloccs.Manifest.{Node,Network,Edge,Port,Effects,Contract,…}` | Typed structs that everything downstream consumes | `lib/bloccs/manifest/{node,network}.ex` |
| `Bloccs.Parser` | TOML → typed struct. Handles node manifests + network manifests, recursive node load, structured error accumulation | `lib/bloccs/parser.ex` |
| `Bloccs.Validator` | Contract enforcement: edge schema-match, DAG-only, effect declaration, MFA well-formedness | `lib/bloccs/validator.ex` |
| `Bloccs.Node` (macro) | `use Bloccs.Node, manifest: "..."`: compile-time parse + validate, `@after_compile` arity check, AST walk warning on undeclared `ctx.effects.X` | `lib/bloccs/node.ex` |
| `Bloccs.Context` + `Bloccs.Effects` | Per-message context with `Capabilities` struct; HTTP/DB/Time/Random adapters with allowlist enforcement; mock backends | `lib/bloccs/context.ex`, `lib/bloccs/effects.ex`, `lib/bloccs/effects/*.ex` |
| `Bloccs.Producer` | Push-based GenStage producer; registered in `Bloccs.Registry` under `{network,node,in_port}` | `lib/bloccs/producer.ex` |
| `Bloccs.Router` | Edge-table dispatch + sink subscriptions for observability/testing | `lib/bloccs/router.ex` |
| `Bloccs.Compiler.{Node,Network}` | Emit Broadway pipeline + Supervisor source files | `lib/bloccs/compiler/{node,network}.ex` |
| `Bloccs.Coverage` | Structural coverage: enumerate port + edge obligations, report reached vs unreached against a trace | `lib/bloccs/coverage.ex` |
| `Bloccs.Trace` | Records a run from telemetry into a `.bloccs-trace`; the coverage reached-set is derived from it | `lib/bloccs/trace.ex` |
| `Mix.Tasks.Bloccs.{New,Validate,Compile,Run,Coverage}` | CLI surface | `lib/mix/tasks/bloccs.*.ex` |

## The unit: a node

A node is one TOML manifest plus one implementation module that `use Bloccs.Node`'s
the manifest. The macro:

1. **Reads** the `.bloccs` file at compile time via `Bloccs.Parser.parse_node/1`.
2. **Validates** via `Bloccs.Validator.validate_node/1`. Bad manifest = `CompileError`.
3. **Generates** module attributes (`@bloccs_manifest`, `@bloccs_declared_effects`,
   etc.) plus accessor functions (`__bloccs_manifest__/0`, `__bloccs_pure_core_ref__/0`).
4. **Hooks** `@after_compile` to check that the declared `pure_core` and
   `effect_shell` functions exist with the right arity, and to AST-walk the
   shell looking for `ctx.effects.X` calls where `X` is not in `[effects]`.

The runtime contract:

- `pure_core(message, ctx) :: {:ok, intermediate} | {:error, reason}`
- `effect_shell(intermediate, ctx) :: {:emit, port, payload} | {:error, reason}`

Pure core is allowed nothing but pure computation. Effect shell receives a
`%Bloccs.Context{}` whose `effects` field is a `%Bloccs.Effects.Capabilities{}`
struct — each declared axis (`http`, `db`, `time`, `random`) is a concrete
adapter; each *undeclared* axis is `%Bloccs.Effects.Denied.Stub{}` whose every
method raises `Bloccs.Effects.Denied`. That's the runtime half of the
capability guarantee.

## The composition: a network

A network manifest is a TOML file declaring `[nodes]` (each `use`-ing a node
manifest), `[[edges]]` (a list of wires), `[expose]` (port renaming for use
as a subgraph — v0.1 stores but doesn't consume), `[supervision]` (strategy
+ restart policy), and `[deploy]` (per-node concurrency overrides).

Parser produces a `%Bloccs.Manifest.Network{}` with every referenced node
manifest loaded recursively. The validator then runs all per-node checks
plus the network-wide ones (edge endpoints exist, edge schemas match
end-to-end, the graph is acyclic, exposes reference real ports, supervision
strategy is one of `:one_for_one | :one_for_all | :rest_for_one`).

## Compilation strategy

`Bloccs.Compiler.compile/2` writes `.ex` source files into
`_build/<env>/bloccs_generated/<network_id>/`:

- One Broadway pipeline module per node (`nodes/<local_id>.ex`)
- One Supervisor module (`supervisor.ex`)

The generated supervisor's `init/1` registers the edge table with
`Bloccs.Router` before starting children, so dispatch is always wired before
any pipeline can emit.

Each generated pipeline module:

```elixir
defmodule Bloccs.Compiled.<Network>.<Node> do
  use Broadway

  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: <pipeline_name>,
      producer: [
        module: {Bloccs.Producer, [name: <producer_name>]},
        concurrency: 1
      ],
      processors: [default: [concurrency: <from manifest [deploy]>]]
    )
  end

  def handle_message(_, msg, _) do
    manifest = <ImplModule>.__bloccs_manifest__()
    ctx      = Bloccs.Context.new(
                 effects: Bloccs.Effects.bind(manifest),
                 received_at: DateTime.utc_now()
               )

    with {:ok, intermediate} <- <ImplModule>.transform(msg.data, ctx),
         {:emit, port, payload} <- <ImplModule>.execute(intermediate, ctx) do
      Bloccs.Router.dispatch(<network>, <local_id>, port, payload)
      msg
    else
      {:error, reason} -> Broadway.Message.failed(msg, reason)
    end
  end
end
```

Why source files instead of `Module.create/3` in memory? Three reasons:

1. **Debuggable stack traces.** Errors point at real file paths.
2. **PR-reviewable.** A topology change shows up as a diff in
   `_build/bloccs_generated/`, not as opaque bytecode.
3. **Agent-readable.** The legibility thesis applies to the compiled artifact
   as much as to the manifest.

## Routing model

```
  upstream node             Router               downstream node
  ──────────────────         ─────                ─────────────────
  effect_shell  ──{:emit, port, payload}──►  dispatch/4
                                                │
                              ┌─── lookup({network, node, port}) → targets
                              │
                              ├── for each {to_node, to_port}:
                              │     producer = Bloccs.Registry.lookup(...)
                              │     GenStage.cast(producer, {:push, payload})
                              │
                              └── for any sink subscriber on the SOURCE port:
                                    send(pid, {:bloccs_sink, network, node, port, payload})
```

The sink subscription model exists for two reasons:

- **Tests.** The integration test in `test/integration/payments_test.exs`
  registers itself as a sink listener on the exposed output ports and asserts
  on the messages it sees.
- **Trace recording.** `Bloccs.Trace` listens on telemetry spans to record a
  run into a `.bloccs-trace`, which `mix bloccs.coverage` reads back.

## Producer / Broadway interaction quirk

Broadway names producer processes itself
(`<pipeline_name>.Broadway.Producer_0`). To give the router a stable address
we ALSO register the canonical name in `Bloccs.Registry` from inside
`Bloccs.Producer.init/1`. This sidesteps the limitation that a BEAM process
can only carry one `Process.register`-style atom name. See
`lib/bloccs/producer.ex` for the registration logic.

## Effect capability model

Two layers of guarantee, by design:

1. **Compile-time** (`Bloccs.Node` `@after_compile`): AST-walk the
   `effect_shell` function, find every `ctx.effects.X.*` access, warn if `X`
   is not declared in `[effects]`. Today this is a `IO.warn/2`; promoting it
   to a hard `CompileError` is a v0.2 goal once we trust the AST inference.
2. **Runtime** (`Bloccs.Effects.bind/1`): builds a `Capabilities` struct
   where every declared axis is a real adapter and every undeclared axis is
   `Denied.Stub`. Calls to `Denied.Stub.*` raise `Bloccs.Effects.Denied`.
   Calls to declared adapters still enforce the per-call allowlist (HTTP
   host, DB scope).

The runtime layer is the load-bearing guarantee. The compile-time layer is
ergonomics — a fast feedback loop telling you "you forgot to declare that
effect."

## How to test the whole thing

```bash
cd app/bloccs
mix check                                     # format + warnings + tests + dialyzer
mix test test/integration/payments_test.exs   # the headline end-to-end assertion
```

The integration test parses `examples/payments/networks/payments.bloccs`,
validates it, compiles it to source files, starts the generated supervisor,
registers itself as a sink listener on the three exposed output ports
(`notify_ok.delivered`, `notify_fail.delivered`, `ledger.committed`), pushes
a charge request into `ingest.http_request`, and asserts the right messages
arrive — once for the Stripe-success path (`notify_ok` + `ledger` both fire,
`notify_fail` doesn't), once for the Stripe-failure path (`notify_fail`
fires alone).

## Shipped since the initial v0.1 cut

- **Subgraph composition** — a `[nodes]` entry may `use` a network manifest; the
  parser flattens it into namespaced leaf nodes.
- **`.bloccs-trace` recording + real coverage** — `Bloccs.Trace` records a run
  from telemetry; `mix bloccs.coverage` reports real structural coverage.

## Deliberately not in v0.1

- **Phoenix LiveView canvas** (v0.3+) — the manifest is canonical; the
  canvas is a view.
- **MCP server** (v0.2) — for agent authoring of `.bloccs` files.
- **Pro / encrypted package distribution** (post-v0.1) — modeled on Oban Pro;
  separate private repo.
- **Polyglot `pure_core`** (HTTP / WASM sidecar refs) — opens up non-BEAM
  cores for the optimization-camp interop story.
- **Multi-input nodes** — a node is currently limited to a single input port
  (the compiler emits one producer per node).
- **Cyclic networks** — v0.1 is DAG-only; cycles unblock the
  self-reflection/iterative-refinement patterns the ACG literature
  catalogues.
- **Full Dialyzer-level effect proof** — v0.1 ships runtime guarantee +
  compile-time warning; hard `CompileError` is a v0.2+ goal once type-row
  inference matures.
