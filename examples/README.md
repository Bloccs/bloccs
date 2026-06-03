# bloccs examples

A graded ladder. Start at the top — each rung adds one idea — then jump to the
flagship to see the whole toolbox on a realistic pipeline. Everything runs with
zero external services.

| Start here | What it teaches | Run |
|---|---|---|
| [`tour/`](tour) · hello | node · port · schema · the parse→validate→compile→run loop | `mix tour.hello` |
| [`tour/`](tour) · pipeline | edges · effects (mock HTTP) · schema-typed wires | `mix tour.pipeline` |
| [`tour/`](tour) · branching | branching · fan-out · multiple out-ports | `mix tour.branching` |
| [`events/`](events) | **the flagship** — HTTP + DB effects, retry, timeout, idempotency, branching, fan-out, coverage on a webhook processor | `mix events.demo` |
| [`real_backend/`](real_backend) | swapping the mock effects for real HTTP (Req) + SQLite (Ecto) | `mix price_watch.demo` |

## How to run them

- **tour** and **real_backend** are standalone mix projects — `cd` in,
  `mix deps.get`, then run the task:

  ```sh
  cd tour && mix deps.get && mix tour.hello
  cd real_backend && mix deps.get && mix price_watch.demo
  ```

- **events** is wired into the bloccs project itself (its node code is part of the
  test build), so run it from the library root:

  ```sh
  cd ..            # app/bloccs
  mix events.demo
  ```

## What to read

Each example has its own `README.md` with a topology diagram and a walkthrough.
For the underlying ideas and every manifest field, see the
[guides](../guides): [concepts](../guides/concepts.md),
[getting-started](../guides/getting-started.md), and the
[manifest reference](../guides/manifest-reference.md).

Want to start a project of your own instead? `mix bloccs.new my_flow` scaffolds a
runnable one-node project — the same shape as `tour`'s first rung.
