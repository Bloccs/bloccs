# Request/response

A bloccs network is asynchronous by default: you push a message in, side effects
come out, and the caller gets nothing back. That is the right shape for webhook
processing, ETL, and fan-out — but not for "validate this and tell me the answer"
or "compute the price and return it", where a caller is waiting on the result.

`Bloccs.call/4` and `Bloccs.cast/4` add request/response **on top of** the async
pipeline, *without making the pipeline synchronous*. Nodes still run concurrently
over Broadway with back-pressure; only the calling process waits.

## Declaring a reply

A terminal node opts in to being the response by setting `reply = true` in its
`[node]` block and emitting the result on an out-port:

```toml
[node]
id      = "price"
version = "0.1.0"
kind    = "sink"
reply   = true

[ports.in]
request = { schema = "Request@1" }

[ports.out]
reply = { schema = "Response@1" }

[contract]
pure_core    = "MyApp.Price.transform/2"
effect_shell = "MyApp.Price.execute/2"
```

When a `reply = true` node emits, its payload is handed back to the caller that
injected the request. Everything else about the node is normal — it can also
edge downstream, run effects, and so on.

## `call/4` — blocking

```elixir
{:ok, %{"total" => 42}} =
  Bloccs.call(:checkout, :request, %{"items" => [...]})
```

`call/4` pushes `payload` into an **exposed input port** (`[expose].in` in the
network manifest) and blocks until the reply node responds or the timeout fires
(default `5_000` ms, override with `timeout:`). It returns:

| Result | Meaning |
| --- | --- |
| `{:ok, payload}` | the reply node's emitted payload |
| `{:error, %Bloccs.EffectError{}}` | a node on the request's trace failed terminally |
| `{:error, :timeout}` | no reply *and* no error in time (e.g. the request was filtered/dropped) |
| `{:error, :no_producer \| :unknown_network \| {:unknown_port, p}}` | the request could not be admitted |

## `cast/4` — async with correlation

```elixir
{:ok, trace_id} = Bloccs.cast(:checkout, :request, payload, send_result: true)
# … later, in the calling process's mailbox:
receive do
  {:bloccs_reply, ^trace_id, {:ok, result}}  -> result
  {:bloccs_reply, ^trace_id, {:error, err}}  -> handle(err)
end
```

`cast/4` returns `{:ok, trace_id}` immediately. With `send_result: true` the
calling process is later sent `{:bloccs_reply, trace_id, result}`. Without it, the
request is fire-and-forget and the `trace_id` is useful only for correlating
telemetry / traces.

## Errors come back as data

A request that fails does **not** hang until the timeout. When a node on the
request's trace fails terminally — a bad inbound schema, the node raising or
returning `{:error, _}`, a `timeout_ms` overrun, or a downstream delivery failure
— the caller receives `{:error, %Bloccs.EffectError{}}`:

```elixir
{:error, %Bloccs.EffectError{node: :price, phase: :execute, attempt: 0, reason: reason}} =
  Bloccs.call(:checkout, :request, bad_payload)
```

`phase` is where it failed (`:validate` | `:execute` | `:dispatch`); `reason` is
the underlying term. A failure that is *retried* (per the node's `[contract].retry`)
is not reported — a later attempt may still succeed and reply.

A request that is legitimately **filtered/dropped** (a node emits `:drop` / `[]`)
produces neither a reply nor an error, so the caller sees `{:error, :timeout}`.
That is the one case worth a deliberate timeout budget.

## How it works

Correlation reuses the per-message `trace_id` (see `Bloccs.Lineage`). `call/4`
mints a root lineage, **registers** the `trace_id` with `Bloccs.Collector` before
pushing (so there is no race with a fast reply), then blocks. The reply node — or
the runtime's terminal-failure path — reports the result to the collector keyed by
that `trace_id`, and the collector hands it to the waiting caller. A result for a
`trace_id` no caller registered is dropped, so plain `Bloccs.Producer.push/3` and
fire-and-forget pipelines pay nothing.

## Limitations

- **First-wins aggregation** — one result per request. A fan-out that produces
  several reply emits per request is not yet supported (an `:all` policy is
  planned).
- **No fan-in on the request path** — a `[batch]` or `[join]` mints a fresh
  `trace_id` by design, which breaks reply *and* error correlation. Keep the reply
  node on the request's 1:1 / split / router trace.
- **One waiter per request** — a second `call/4` on the same in-flight `trace_id`
  returns `{:error, :already_awaited}` (you cannot normally construct this; ids
  are unique per request).
