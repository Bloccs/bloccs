# Changelog

All notable changes to `bloccs` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — flow primitives

- **Filter + multi-emit** — the effect shell may return `:drop` (filter — emit
  nothing) or `{:emit, [{port, payload}, …]}` (split — many messages / ports at
  once), in addition to the single `{:emit, port, payload}`. A drop emits a
  `[:bloccs, :node, :dropped]` event.
- **Merge (fan-in)** — several edges may target one in-port (an undifferentiated,
  unordered merge); no special construct needed.
- **Aggregate / batch / window** — a `[batch]` block (`size` / `timeout_ms`)
  makes a node process messages in windows via Broadway batchers; its `pure_core`
  receives the list of payloads and reduces them.
- **Join (multi-input)** — a `[join]` block correlates two or more distinct typed
  in-ports by a key field (`on`); each in-port compiles to its own pipeline and
  arrivals are matched in `Bloccs.Join`, with a `deadletter` out-port for partials
  that exceed `timeout_ms`. This lifts the single-input-port limit for join nodes.
- **Throttle + delay** — `[rate]` (Broadway producer rate limiting) and `[delay]`
  (producer time-shift). Debounce is a time-windowed `[batch]`.

### Known limitations

- **Cyclic networks** remain out of scope (DAG-only); feedback loops need a
  deadlock-safe edge mode still on the roadmap.

## [0.1.0] — unreleased (pre-release)

First pre-release. Not yet published to Hex; APIs may change before `0.1.0` is
tagged on Hex.

### Added

- **Manifest formats** — TOML node manifests (`.bloccs`, one node per file) and
  network manifests, parsed into typed structs (`Bloccs.Manifest.*`) by
  `Bloccs.Parser`.
- **Validator** — `Bloccs.Validator` enforces declared ports, end-to-end edge
  schema matching, DAG-only topology (cycle detection), effect declaration, and
  well-formed `pure_core`/`effect_shell` function refs.
- **`use Bloccs.Node`** — compile-time parse + validate of a node's manifest,
  `@after_compile` arity check of the contract functions, and an AST-walk warning
  on use of undeclared effects.
- **Code generator** — `Bloccs.Compiler` emits a Broadway supervision tree as
  real `.ex` source under `_build/<env>/bloccs_generated/<network>/` (debuggable,
  PR-reviewable), one pipeline module per node plus a supervisor.
- **Runtime contracts**, wired into the generated `handle_message`: retry
  (constant/linear/exponential back-off, matched on failure reason), `timeout_ms`
  (bounded task per attempt), idempotency (atomic in-flight reservation by key),
  bounded-buffer back-pressure (producer parks the caller, never drops), and
  `:telemetry` spans.
- **Effect capability model** — pure core + effect shell split; four effect axes
  (`http`, `db`, `time`, `random`); declared axes bind to real adapters,
  undeclared axes bind to a `Denied.Stub` that raises. Mock adapters by default;
  real `Bloccs.Effects.HTTP.Req` and `Bloccs.Effects.DB.Ecto` behind a config
  switch, with `:req`/Ecto as optional deps.
- **Subgraph composition** — a `[nodes]` entry may `use` a network manifest; the
  parser flattens it into namespaced leaf nodes at parse time.
- **Trace + coverage** — `Bloccs.Trace` records a run from telemetry to a
  `.bloccs-trace`; `mix bloccs.coverage` reports real structural coverage
  (in-ports, out-ports, edges reached) live (`--message`) or from a loaded trace
  (`--trace`).
- **CLI** — `mix bloccs.new`, `mix bloccs.validate`, `mix bloccs.compile`,
  `mix bloccs.run` (with `--message`, `--port`, `--trace`), `mix bloccs.coverage`.
- **Examples** — a graded ladder: `examples/tour` (core concepts, mock effects),
  `examples/events` (the flagship webhook processor — branching, fan-out, retry,
  timeout, idempotency, coverage), and `examples/real_backend` (real HTTP to a
  local stub + real SQLite, `mix price_watch.demo`).
- **Guides** — core concepts, getting started, manifest reference, architecture,
  and effect adapters.

[Unreleased]: https://github.com/Bloccs/bloccs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Bloccs/bloccs/releases/tag/v0.1.0
