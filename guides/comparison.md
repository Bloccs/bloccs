# How bloccs compares

The question every evaluator asks: *why this instead of the thing I already use?*
This page is an honest map. bloccs is **pre-release and BEAM-native**: an
in-memory, typed dataflow graph that compiles to a Broadway/GenStage supervision
tree. It has **no durable persistence** and is **DAG-only** in v0.1. Keep that in
mind below.

## At a glance

| Tool | Shape | Durable? | Use it instead of bloccs when… |
|---|---|---|---|
| **Broadway** (directly) | one data-ingestion pipeline | no | you have a single producer→processors→batchers stage, not a graph of typed stages |
| **Oban** | DB-backed job queue | yes (Postgres/SQLite) | work must survive restarts, be scheduled/cron'd, or be uniquely deduped across time |
| **Reactor** (Ash) | per-invocation saga / dependency graph | no (in-process) | you orchestrate one request's steps with rollback/compensation, then return |
| **Temporal** | durable execution, workflow-as-code | yes (event history) | you need cross-service, multi-day workflows that survive process/host crashes |
| **LangGraph** | Python agent graph (cyclic, shared state) | optional checkpoints | you're in Python and building dynamic LLM agent loops |
| **plain GenServer/Task** | bespoke processes | no | the work isn't a dataflow graph — it's ad-hoc state or one-off concurrency |

## Why not Broadway directly?

bloccs **generates** Broadway — it isn't an alternative to it. Reach past bloccs
straight to Broadway when your problem is *one* pipeline: ingest from SQS/Kafka,
process, batch, done. Broadway is the right tool and bloccs would only add a
layer.

Reach for bloccs when you have a **graph of stages** and want the things you'd
otherwise hand-wire to be declared and checked:

- **Typed edges.** Ports carry versioned `Name@N` schemas; the validator rejects a
  network that wires mismatched schemas *before* it runs. Hand-wired Broadway has
  no contract between pipelines.
- **Effects as capabilities.** Each node declares the HTTP hosts / DB scopes /
  clock / randomness it may touch; undeclared use is refused at runtime and warned
  at compile time. Broadway has no opinion on what a processor may do.
- **Per-node policy in the manifest.** Retry, timeout, idempotency, and bounded
  back-pressure are declared, not re-implemented per pipeline.
- **The topology is a reviewable artifact.** A network is a TOML file, and the
  compiled supervision tree is real `.ex` source you can diff in a PR — not a
  hand-maintained supervisor module.

If you have exactly one stage, that overhead isn't worth it. If you have a graph,
it is.

## Oban

Different axis entirely. **Oban is a durable job queue** backed by your database:
persistence across restarts, scheduling, cron, unique jobs, back-off. **bloccs is
in-memory dataflow** — when the node crashes, its supervisor restarts it, but
in-flight messages are not persisted.

Use Oban when the unit of work is a *job* that must not be lost. Use bloccs when
the unit of work is a *message flowing through a graph*. They compose cleanly: a
bloccs effect shell can enqueue an Oban job, and an Oban worker can push a message
into a bloccs network. bloccs does not try to be durable; if you need durability
today, put Oban (or a broker) at the edges.

## Reactor (Ash)

Reactor is a **saga executor**: you describe steps with dependencies and
compensations, and Reactor runs them for a single invocation, rolling back on
failure. It shines for "do these five things as one transaction, undo on error,
return a result."

bloccs is a **standing pipeline**: long-running, supervised, back-pressured,
processing a stream of messages — not a per-call transaction with rollback. If
your mental model is "run this workflow and give me the answer," that's Reactor.
If it's "messages continuously flow through this topology," that's bloccs.

## Temporal

Temporal is **durable execution** as a service: workflow code whose state is
persisted to an event history, so it survives crashes and can run for days,
retrying across failures with exactly-once-ish guarantees. It's polyglot and
cross-service.

bloccs is BEAM-native and in-memory, with no durable history. Choose Temporal for
long-lived, cross-service orchestration where durability is the whole point.
Choose bloccs for BEAM-local typed dataflow where supervision + back-pressure are
enough and you don't want to operate a Temporal cluster.

## LangGraph

LangGraph is a **Python** framework for agent graphs — dynamic, often cyclic,
LLM-call nodes sharing mutable state, with optional checkpointing. It's the place
to prototype agent loops in the Python ecosystem.

bloccs targets **production BEAM systems**: typed, compiled, supervised, with
explicit effects and back-pressure, DAG-only in v0.1 (cycles are roadmap). It is
not a Python tool and not a notebook-first experience. The overlap is conceptual —
both are "computation graphs" — but the ecosystem and the production guarantees
differ.

## Plain GenServers / Tasks

bloccs deliberately forbids hand-rolled GenServers and Tasks *inside the
generated topology* in favor of declared structure (Broadway + GenStage +
supervisors). That's a feature for dataflow: you get back-pressure, supervision,
and a legible graph for free.

It is not a feature when your problem isn't a graph. Bespoke stateful processes,
one-off concurrency, and custom protocols are exactly what GenServer/Task are for.
Use bloccs for the dataflow; use the BEAM primitives for everything else.

---

**Short version:** bloccs is for *typed, inspectable dataflow graphs on the BEAM*
that need explicit effects, back-pressure, retries, and a generated supervision
tree. If you need durability, reach for Oban or Temporal at the edges; if you have
a single pipeline, use Broadway directly; if you need per-call sagas, use Reactor.
