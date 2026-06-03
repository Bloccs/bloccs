# Changelog

All notable changes to `bloccs` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Known limitations

- Nodes are limited to a **single input port**; the compiler does not yet emit a
  producer per in-port for multi-input nodes.
- `Bloccs.Router.dispatch/4` does not surface downstream delivery failures
  (`:no_producer`, push timeout) to the caller.

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
- **Examples** — `examples/payments` (fully mocked end-to-end network) and
  `examples/real_backend` (real HTTP to a local stub + real SQLite,
  `mix price_watch.demo`).
- **Guides** — core concepts, getting started, manifest reference, architecture,
  and effect adapters.

[Unreleased]: https://github.com/Bloccs/bloccs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Bloccs/bloccs/releases/tag/v0.1.0
