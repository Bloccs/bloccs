# Changelog

All notable changes to `bloccs` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.11.0] — 2026-06-25

### Added

- **Capability linter (`Bloccs.Node.EffectLint`)** — a compile-time pass that
  makes the declared-capability facade the **only** legal path to the world from
  a node body. It walks the `pure_core` and `effect_shell` clause bodies and
  rejects, as a `CompileError`, any call that reaches the world outside the
  facade: direct IO (`File.*`, `IO.*`, `System.cmd`), HTTP clients (`Req`,
  `:httpc`, …), storage (`:ets`, raw sockets), process/messaging escapes
  (`spawn`, `send`, `receive`, `Task.*`), ambient nondeterminism
  (`DateTime.utc_now` → the `time` effect), config mutation
  (`Application.put_env`), and unanalyzable dynamic dispatch (`apply/3`, calls on
  a computed module, captures of denied modules). Permitted: the effect facade
  (`effect_shell` only — `pure_core` must be side-effect-free), a curated pure
  stdlib, read-only `Application` config, and modules in the node's own OTP app.

  This upgrades the previous **advisory** effect check (an `IO.warn` that only
  saw `ctx.effects.X` misuse and never direct calls) into an **enforced**
  guarantee. Within the trusted base (the linter + the effect adapters) a node's
  declared capabilities are now unbypassable for the restricted module surface —
  it is no longer necessary to read a node body line-by-line to know it can't
  touch undeclared IO. It is a capability *discipline*, not a sound effect system
  (see the module's "Honest scope" notes).

- **`[lint]` manifest section** — `effects = "off"` opts a node out of
  enforcement (violations downgrade to a single loud warning, and the opt-out is
  recorded on the manifest so tooling can flag the node for review);
  `allow = ["My.Vetted.Lib"]` permits specific extra modules without turning
  enforcement off wholesale.

### Changed

- ⚠️ **Behavior change.** Node bodies that reached the world outside the facade
  used to compile (with at most a warning); they are now a compile error by
  default. Migrate by routing the call through a declared effect
  (`ctx.effects.http/db/time/random`), or — for a vetted exception — add the
  module to `[lint] allow` or set `[lint]\n effects = "off"` on that node.

## [0.10.0] — 2026-06-15

### Added

- **`mix bloccs.gen.node <name>` and `mix bloccs.gen.network <name>`** — add a
  node (manifest + pure-core/effect-shell implementation) or a network manifest
  to an **existing** Mix project, the gap `mix bloccs.new` (whole-project
  scaffold) didn't cover. `gen.node` takes `--kind transform|source|sink|router`
  (skeletons the ports and the effect-shell return) and `--module <Base>`
  (defaults to the current app); `gen.network` seeds `[nodes]` from repeatable
  `--node` flags. Both refuse to overwrite existing files.

## [0.9.1] — 2026-06-15

Docs and positioning, no code changes.

### Added

- **`llms.txt`** at the repo root (and in the Hex package): a machine-readable
  summary for coding assistants — what bloccs is and isn't, when to use it, when
  not to, and links to every guide. Disambiguates bloccs (a dataflow-graph
  library) from "blocks" page-builders.
- **`guides/recipes.md`** — copy-pasteable end-to-end manifests for the common
  shapes: bulk classification through a rate-limited model (back-pressured),
  multi-stage RAG, entering a network from a web request, and composing Oban at
  the edges for durability.
- **`boundary` in the comparison guide** — when to reach for compile-time
  module-dependency isolation versus bloccs' declared-I/O effects, and how they
  compose.

### Changed

- **README maturity framing.** The header note no longer reads as
  "prototyping-grade"; it now separates pre-1.0 API churn (still true) from the
  runtime's production posture (supervised, back-pressured, capability-checked),
  with durability called out as an explicit design boundary to put Oban at, not a
  maturity gap.

## [0.9.0] — 2026-06-11

A hardening release: every change makes an existing guarantee true rather than
adding surface. No manifest-format changes; one new telemetry event.

### Security

- **HTTP redirects are re-checked against the allowlist on every hop.**
  `Bloccs.Effects.HTTP.Req` previously let Req auto-follow 3xx responses to
  *any* host — a declared host that redirected to an undeclared one (e.g. a
  cloud metadata address) was silently followed. Auto-redirect is now off;
  each hop's **host and method** are re-validated before the request is made,
  capped at 10 hops (`{:error, {:too_many_redirects, url}}` beyond). A 303 —
  and 301/302 on a non-GET — downgrades to a body-less GET, which is also
  re-checked. Host matching is now case-insensitive, matching DNS.
- **SQL identifiers are validated in `Bloccs.Effects.DB.Ecto`.** Table and
  column names (insert attrs, read filters, update changes) were interpolated
  into SQL unvalidated — values were parameterized, but a column name derived
  from a message payload was an injection vector. Every identifier must now
  match `[A-Za-z_][A-Za-z0-9_]*`; anything else raises
  `Bloccs.Effects.Denied` before any SQL is built.
- **`random = "crypto"` is now cryptographic.** Both modes previously drew
  from `:rand` (predictable). Crypto mode now uses
  `:crypto.strong_rand_bytes/1` via unbiased rejection sampling. An
  unrecognized mode is denied on first use instead of minting an atom from
  manifest input.
- **No more payload-driven atom creation.** Validating a `{:list, _}` schema
  field minted one atom per element per validation (atoms are never GC'd — a
  single large hostile payload could crash the VM); element names in error
  messages are now plain binaries. `Bloccs.Trace.load/1` now decodes node/port
  names with `String.to_existing_atom/1` and drops events referencing unknown
  names — a corrupt or hostile `.bloccs-trace` can no longer grow the atom
  table.

### Fixed

- **The parser is total over malformed TOML.** Five malformed-but-valid-TOML
  shapes (dotless or non-string `[expose]` endpoints, non-string `[join]`
  `deadletter`, non-string entries in `http.methods`, non-string `use` paths,
  non-table `[deploy].concurrency`) crashed with raw exceptions instead of the
  structured errors the parser promises. All now return `%Bloccs.Parser.Error{}`s.
- **`[effects]` misdeclarations are parse errors, not silent nils.** An
  unknown axis (e.g. a typo'd `htttp`) or a misshapen `http`/`db`/`time`/`random`
  declaration was silently discarded — indistinguishable from "nothing
  declared", surfacing only as an inexplicable capability denial at runtime.
- **Cycle detection is linear-time.** The DFS's memoization set was never
  written to, so diamond-shaped DAGs enumerated O(2^depth) paths — a 61-node
  diamond chain took ~3 s to validate and ~90 nodes effectively hung the CLI.
  Validation of a 121-node diamond chain is now sub-millisecond.
- **The compile-time effect warning now fires in consumer apps.** The
  undeclared-effect AST check depended on a dev/test-only dependency
  (`ex_ast`), so it silently never ran when bloccs was used as a dependency —
  exactly where it matters. It is now a dependency-free `Macro.prewalk`, and
  matches the `.effects.<axis>` chain on **any** context variable name (no
  longer only `ctx`). The `ex_ast` dependency is gone.
- **Router restarts no longer silently destroy routing.** Edge tables moved
  from Router state to `:persistent_term` (written once per network boot):
  previously a Router restart meant every subsequent dispatch found zero
  targets and **acked successfully into the void**. Dispatch to a network with
  no registered table now fails loudly (`:network_not_registered` + a
  `[:bloccs, :dispatch, :error]` event), and edge lookups no longer serialize
  through the singleton. Adds `Bloccs.Router.unregister/1`.
- **Retries survive producer restarts.** A scheduled retry targeted the
  producer *pid* captured at schedule time — if the producer restarted before
  the timer fired, the retry vanished silently and its idempotency key stayed
  wedged until the TTL sweep. The timer now re-resolves the canonical name at
  fire time; a retry that still can't be delivered emits the new
  `[:bloccs, :producer, :enqueue_lost]` event and releases its reservation. A
  retry that can't even be *scheduled* fails the message instead of acking it.
- **`Bloccs.call/4` with `timeout: :infinity` no longer kills the Collector**
  (and every in-flight request across all networks with it). Infinite
  deadlines simply skip the expiry timer.

### Added

- `[:bloccs, :producer, :enqueue_lost]` telemetry — emitted when a scheduled
  re-enqueue (retry) cannot be delivered because its producer is gone. The
  loss windows of a non-durable runtime are unchanged; this release's rule is
  that none of them may be *silent*.

## [0.8.0] — 2026-06-08

### Added

- **Introspection exposes `reply` and per-axis effect detail.** Each node view
  from `Bloccs.Introspect.network/1` now carries:
  - `reply` — the node's `reply = true` flag (request/response terminal), so an
    observer can mark reply nodes.
  - `effect_detail` — the declared detail per effect axis (`nil` when undeclared):
    `db` carries its `allow` scopes (`"table:read"`, `"table:insert"`, …), `http`
    its allowed hosts + methods, `time`/`random` their modes. The existing
    `effects` field (the list of declared axes) is unchanged.

  Additive — existing fields keep their shape. This lets observability tools
  (e.g. the bloccs_web dashboard) surface reply nodes and DB read/write scopes
  that 0.6.0 / 0.7.0 introduced.

## [0.7.0] — 2026-06-08

### Added

- **DB reads — `Bloccs.Effects.DB.get/3`, `all/3`, `one/3`.** The `db` effect was
  write-only; it can now read, behind a new `"table:read"` scope (declare it
  alongside `"table:insert"` in `[effects].db.allow`). `get/3` fetches by primary
  key (`id`); `all/3` / `one/3` take an ANDed equality filter (`%{column =>
  value}`, empty = all). Rows return as **string-keyed maps** from both backends,
  so node logic is backend-agnostic. `one/3` returns `{:ok, nil}` for no match and
  `{:error, :multiple_results}` for more than one.

  - `DB.Mock` serves reads from its in-memory insert log (still hermetic, no DB).
  - `DB.Ecto` runs a parameterized `repo.query!/2` — the only read path needing no
    compile-time `Ecto.Query` macro, preserving the "no Ecto unless you use the DB
    axis" guarantee. Placeholders are adapter-detected (`$n` for Postgres, `?`
    otherwise) and identifiers double-quoted, so **Postgres and SQLite3** are
    supported; richer queries / other dialects → implement the `Bloccs.Effects.DB`
    behaviour directly.

  A read is an effect (lives in `effect_shell`); together with `Bloccs.call/4` this
  enables the *receive → read → decide → write → reply* shape.

- **DB update / delete — `Bloccs.Effects.DB.update/4`, `delete/3`.** Behind
  `"table:update"` / `"table:delete"` scopes, keyed by primary `id`; both return
  `{:ok, rows_affected}`. `update/4` takes `%{column => value | {:inc, n}}`, where
  `{:inc, n}` compiles to `SET col = col + n` — a **read-free atomic increment**
  (negative `n` decrements), the correct primitive for counters.

- **DB transactions — `Bloccs.Effects.DB.transaction/2`.** Runs a unit of work
  atomically, as either a function (`fn db -> {:ok, result} | {:error, reason} end`
  — inner DB calls run in the transaction) or a declarative list of ops
  (`{:insert, …}` / `{:update, …}` / `{:delete, …}`, run in order, short-circuiting
  on the first error as `{:error, {index, reason}}`). Returning `{:error, _}` or
  raising rolls everything back; each inner op is scope-checked. `DB.Ecto` maps to
  `repo.transaction/1` + `repo.rollback/1` (no compile-time Ecto); `DB.Mock`
  snapshots and restores its store, so tests get real atomicity with no database.
  This makes the read-free atomic-counter pattern (insert + `{:inc, 1}`)
  expressible in one atomic unit. See `research/13-db-read-write-effect.md`.

- **Request/response observability.** The `Bloccs.call/4` / `cast/4` lifecycle is
  now observable (for dashboards and metrics handlers):
  - `Bloccs.Collector` emits `[:bloccs, :request, :start]` on register and
    `[:bloccs, :request, :stop]` on resolution — metadata `%{network, trace_id,
    mode}` with, on stop, `:outcome` (`:reply | :error | :timeout`), a `:duration`
    measurement, and the `%Bloccs.EffectError{}` under `:error` on a failure. The
    `trace_id` ties a request to the `[:bloccs, :emit]` / `[:bloccs, :node, *]`
    events of the messages it spawned. (The default logger also reports it.)
  - `Bloccs.Collector.stats/0` returns a snapshot of in-flight requests
    (`%{in_flight, by_network}`).

### Added

- **Request/response — `Bloccs.call/4` and `Bloccs.cast/4`.** A network was until
  now fire-and-forget: `Bloccs.Producer.push/3` returns once a message is
  *admitted*, never once it is *processed*, so a caller got nothing back. The new
  functions add request/response on top **without making the pipeline
  synchronous** — only the calling process waits.

  - A terminal node opts in with `reply = true` in its `[node]` block and emits
    the response on an out-port.
  - `Bloccs.call(network_id, in_port, payload, opts)` pushes to an exposed input
    port and blocks until that node replies, returning `{:ok, reply}` or
    `{:error, reason}`. `:timeout` defaults to `5_000` ms.
  - `Bloccs.cast(network_id, in_port, payload, opts)` returns `{:ok, trace_id}`
    immediately; with `send_result: true` the caller is later sent
    `{:bloccs_reply, trace_id, result}`.

- **Errors come back as data — `Bloccs.EffectError`.** When a node on a request's
  trace fails terminally — a bad inbound schema (`:validate`), the node raising /
  returning `{:error, _}` / a `timeout_ms` overrun (`:execute`), or a downstream
  delivery failure (`:dispatch`) — the caller receives `{:error,
  %Bloccs.EffectError{node, phase, attempt, reason}}` instead of waiting out the
  timeout. So `call/4` can tell "failed" from "slow"; `{:error, :timeout}` is
  reserved for a request that is legitimately filtered/dropped (no reply *and* no
  error). `cast/4` with `send_result: true` delivers the typed error the same way.
  A *retried* failure is not reported (a later attempt may still reply). The other
  `{:error, _}` reasons are `:no_producer | :unknown_network | {:unknown_port, p}`
  (the request could not be admitted).

  Correlation reuses the per-message `trace_id` (`Bloccs.Lineage`): the new
  `Bloccs.Collector` process keys an in-flight request on `{network_id, trace_id}`,
  registered synchronously *before* the push (so a reply/error for an unregistered
  trace is dropped, not buffered — plain `push/3` and fire-and-forget `reply =
  true` nodes cost the collector nothing) and enforces the timeout collector-side
  (a late reply can never crash a timed-out caller).

  Limitations: first-wins aggregation (one result per request); correlation
  (reply *and* error) does not survive a `[batch]`/`[join]` (which mint a fresh
  `trace_id`). See `Bloccs.Collector`, the
  [request/response guide](guides/request-response.md), and
  `research/12-request-response-primitive.md`.

## [0.5.0] — 2026-06-07

### Added

- **Per-message lineage tracking.** Every message now carries a small lineage in
  its `Broadway.Message` metadata (never the payload) so a single logical message
  can be tracked across the hops it takes through a network:

      %{msg_id: id, parents: [id], trace_id: id}

  - `msg_id` — a unique id minted at each emit.
  - `parents` — the input message id(s) that caused this emit: one for a
    transform/split, **many** for a batch/join fan-in (a causal DAG).
  - `trace_id` — root correlation; propagated unchanged on 1:1 and fan-out, and
    minted fresh on fan-in (a merge is a new logical message; `parents` preserves
    the cross-trace links).

  A root lineage is minted at external ingress; `Bloccs.Router.dispatch/5`
  threads it to each downstream producer and the runtime stamps it at every emit
  site (transform, split, filter, batch, join, join deadletter, retry). Subgraph
  composition needs no special handling — `use` is flattened into one namespaced
  network at parse time, so lineage threads across the seam for free.

  The `[:bloccs, :emit]` telemetry metadata gains `:msg_id`, `:parents`,
  `:trace_id` (additive — existing consumers are unaffected). See the new
  `Bloccs.Lineage` module.

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

[Unreleased]: https://github.com/Bloccs/bloccs/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/Bloccs/bloccs/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/Bloccs/bloccs/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/Bloccs/bloccs/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Bloccs/bloccs/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Bloccs/bloccs/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Bloccs/bloccs/compare/v0.3.0...v0.4.0
[0.1.1]: https://github.com/Bloccs/bloccs/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Bloccs/bloccs/releases/tag/v0.1.0
