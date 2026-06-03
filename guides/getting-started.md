# Getting started

This walks the full **parse → validate → compile → run** loop: you'll scaffold a
project, write a node, wire it into a network, and run a message through it. It
assumes you've skimmed [Core concepts](concepts.md) — node, port, effect, schema,
pure-core/effect-shell, network, edge.

> bloccs targets Elixir `~> 1.18` on the BEAM.

## 1. Add the dependency

```elixir
# mix.exs
def deps do
  [
    {:bloccs, "~> 0.1"}
  ]
end
```

`:req` (for the real HTTP adapter) and Ecto (for the real DB adapter) are
*optional* — bloccs ships with mock adapters by default, so you add those only
when you want real backends. See [Effect adapters](effect-adapters.md).

## 2. Scaffold a project layout

```bash
mix bloccs.new my_flow
```

This writes a starter tree with one sample node and a one-node network:

```
my_flow/
├── nodes/hello.bloccs       # a node manifest
└── networks/hello.bloccs    # a network manifest wiring it up
```

You can immediately validate and compile what it generated (steps 4–5). The rest
of this guide builds a node by hand so you see every part.

## 3. Write a node

A node is **one manifest + one implementation module**.

### The manifest (`nodes/greet.bloccs`)

```toml
[node]
id      = "greet"
version = "0.1.0"
kind    = "transform"

[doc]
intent = "Uppercase a name and greet it."
owner  = "@me"

[ports.in]
name_received = { schema = "Name@1" }

[ports.out]
greeted = { schema = "Greeting@1" }

# No external world touched → no [effects] block needed.

[contract]
pure_core    = "MyFlow.Nodes.Greet.transform/2"
effect_shell = "MyFlow.Nodes.Greet.execute/2"
```

### The implementation (`lib/nodes/greet.ex`)

`use Bloccs.Node` reads and validates the manifest at compile time. The two
functions named in `[contract]` are the **pure core** and **effect shell**:

```elixir
defmodule MyFlow.Nodes.Greet do
  use Bloccs.Node, manifest: "../../nodes/greet.bloccs"

  # pure core: no IO, just computation
  @spec transform(map(), Bloccs.Context.t()) :: {:ok, map()} | {:error, term()}
  def transform(%{name: name}, _ctx) when is_binary(name) do
    {:ok, %{message: "Hello, #{String.upcase(name)}!"}}
  end

  def transform(_, _ctx), do: {:error, :invalid_name}

  # effect shell: would touch the world here; this node just emits
  @spec execute(map(), Bloccs.Context.t()) :: {:emit, atom(), map()}
  def execute(intermediate, _ctx) do
    {:emit, :greeted, intermediate}
  end
end
```

A node that *does* touch the world declares the capability in `[effects]` and
reaches it through `ctx.effects` in the shell — for example
`Bloccs.Effects.HTTP.post(ctx.effects.http, url, body)`. Any effect you use but
didn't declare is refused at runtime (and warned at compile time).

### Register the schemas

Ports reference `Name@N` schemas; register them at app start:

```elixir
# lib/my_flow/schemas.ex
defmodule MyFlow.Schemas do
  alias Bloccs.Schema

  def register do
    Schema.register("Name@1", name: :string)
    Schema.register("Greeting@1", message: :string)
    :ok
  end
end
```

Call `MyFlow.Schemas.register/0` from your application's `start/2`.

## 4. Validate

```bash
mix bloccs.validate nodes/greet.bloccs
```

`bloccs.validate` auto-detects node vs network manifests. It checks ports are
declared, effects are well-formed, the `pure_core`/`effect_shell` refs are
well-shaped, and (for networks) that edges connect real ports with matching
schemas and form a DAG. Errors are printed with file + section pointers; the task
exits non-zero on failure.

## 5. Wire a network

```toml
# networks/greet.bloccs
[network]
id      = "greet"
version = "0.1.0"
runtime = "beam"

[nodes]
greet = { use = "../nodes/greet.bloccs" }

[expose]
in  = { input  = "greet.name_received" }
out = { output = "greet.greeted" }

[supervision]
strategy     = "one_for_one"
max_restarts = 5
max_seconds  = 60
```

Validate it, then compile it:

```bash
mix bloccs.validate networks/greet.bloccs
mix bloccs.compile  networks/greet.bloccs
```

`bloccs.compile` emits **real `.ex` source** to
`_build/<MIX_ENV>/bloccs_generated/greet/` — one Broadway pipeline module per
node plus a supervisor. Open them: legible output is a feature, not a
side effect.

## 6. Run a message through it

```bash
mix bloccs.run networks/greet.bloccs --message '{"name": "ada"}'
```

`bloccs.run` compiles the network, starts the generated supervisor, and feeds the
JSON message into the exposed input port (defaults to the first `[expose].in`
entry; override with `--port`). Without `--message` it starts the tree and waits
so you can drive it from IEx or a test.

To record what the run touched:

```bash
mix bloccs.run networks/greet.bloccs --message '{"name": "ada"}' --trace run.bloccs-trace
mix bloccs.coverage networks/greet.bloccs --trace run.bloccs-trace
```

`bloccs.coverage` reports every in-port, out-port, and edge against the set the
run actually reached.

## Where to go next

- [Manifest reference](manifest-reference.md) — every TOML field, typed.
- [Effect adapters](effect-adapters.md) — swap the mock HTTP/DB adapters for real
  `Req`/`Ecto`.
- [Architecture](ARCHITECTURE.md) — how the compile pipeline and runtime are
  built, module by module.
- `examples/` in the repo — a graded ladder: [`tour`](../examples/tour)
  (core concepts, `mix tour.hello`), [`events`](../examples/events) (the flagship
  webhook processor, `mix events.demo`), and [`real_backend`](../examples/real_backend)
  (a real-HTTP-to-SQLite demo, `mix price_watch.demo`).
