# Changelog

All notable changes to `bloccs` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] — 2026-06-07

### Added

- **`Bloccs.Introspect` now exposes each node's contract and primitive config.**
  `node_view/1` gained two fields so observability tools can show *what code runs
  at a node* and *how a primitive is tuned* without re-parsing manifests:
  - `:contract` — the author's `pure_core` / `effect_shell` refs (as
    `"Mod.fun/arity"`), plus `timeout_ms`, `retry`, and `idempotency` policy.
  - `:config` — the primitive block a node declares, as the relevant
    `Bloccs.Manifest.{Batch,Join,Rate}` struct (or `delay_ms`), `nil` when absent.

  Both are additive; existing `node_view` consumers are unaffected.

## [0.3.0] — 2026-06-05

### Added

- **`Bloccs.Inspect` — opt-in payload capture.** Off by default. When enabled,
  the runtime attaches a rendered, **bounded**, **redacted** snapshot of each
  emitted payload to the `[:bloccs, :emit]` telemetry event under the new
  `:payload` metadata key (a string; `nil` when disabled), so observability tools
  (e.g. the `bloccs_web` Messages feed) can show message contents without holding
  the live term.

  ```elixir
  config :bloccs, :inspect,
    enabled: true,
    max_bytes: 512,
    redact: [:password, :token, :secret, :authorization]
  ```

  Redaction matches map keys by name (atom or string) at any depth; structs keep
  their type.

### Changed

- **Relicensed from MIT to Apache License 2.0** (adds an explicit patent grant).
  Applies to this and future releases; previously published versions (≤ 0.2.0)
  remain under their original MIT terms.

## [0.2.0] — 2026-06-05

### Added

- **Introspection API** — a read-only window into running networks, the
  foundation an observability dashboard (`bloccs_web`) reads. All additive.
  - `Bloccs.Introspect` — `list_networks/0` (summaries), `network/1` (a
    normalized `Bloccs.Introspect.Network` with nodes, ports, effects, edges,
    per-node concurrency, supervision strategy, and exposed ports), `producers/1`,
    and `producer_state/1`.
  - `Bloccs.Introspect.glyph/1` — the canonical notation glyph for a node
    manifest (`:source`, `:sink`, `:split`, `:batch`, `:join`, `:throttle`,
    `:delay`, `:node_effect`, `:node`), so the notation stays a property of the
    library rather than being reinvented by each viewer.
  - `Bloccs.Discovery` — boot-time registration of running networks in a new
    `Bloccs.NetworkRegistry`, so tools enumerate live networks in O(1) without
    scanning the supervision tree. Entries are owned by each network's supervisor
    and clean up automatically when it stops or crashes. The generated supervisor
    now calls `Bloccs.Discovery.register/2` from `init/1` — **recompile networks
    built with an older bloccs** (`mix bloccs.compile`) to make them discoverable.
  - `Bloccs.Producer.stats/1` — a safe, typed snapshot of a producer's queue
    (`size`, `buffer`, `blocked`, `pending_demand`, `utilization`) via a bounded
    `GenStage` call, so observers never reach in with `:sys.get_state`.
  - The generated supervisor gained `__bloccs_introspect__/0` (topology + node→impl
    + supervision + exposed ports) feeding the API above.

## [0.1.1] — 2026-06-05

### Changed

- Docs: dropped the README Status and "Out of scope" sections (the roadmap now
  lives in GitHub Projects), corrected the License note to plain MIT (no Pro
  call-out), and refreshed the post-publish wording now that bloccs is on Hex.

## [0.1.0] — 2026-06-05

First public release.

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
  undeclared axes bind to a denied-capability stub that raises. Mock adapters by
  default; real `Bloccs.Effects.HTTP.Req` and `Bloccs.Effects.DB.Ecto` behind a
  config switch, with `:req`/Ecto as optional deps.
- **Flow primitives** — `:drop` (filter) and `{:emit, [{port, payload}, …]}`
  (split / multi-emit) effect-shell return shapes alongside the single
  `{:emit, port, payload}`; **merge** (several edges into one in-port);
  **`[batch]`** windows (`size` / `timeout_ms`) reduced by `pure_core`;
  **`[join]`** correlating two or more distinct typed in-ports by a key (`on`) —
  each in-port compiles to its own pipeline; partials past `timeout_ms`
  dead-letter; **`[rate]`** throttle and **`[delay]`** time-shift via the Broadway
  producer. A filtered message emits `[:bloccs, :node, :dropped]`.
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
  local stub + real SQLite).
- **Guides** — core concepts, getting started, manifest reference, architecture,
  and effect adapters.

### Known limitations

- **Cyclic networks** are out of scope (DAG-only); feedback loops need a
  deadlock-safe edge mode still on the roadmap.

[Unreleased]: https://github.com/Bloccs/bloccs/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Bloccs/bloccs/compare/v0.3.0...v0.4.0
[0.1.1]: https://github.com/Bloccs/bloccs/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Bloccs/bloccs/releases/tag/v0.1.0
