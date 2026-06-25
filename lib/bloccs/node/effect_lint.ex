defmodule Bloccs.Node.EffectLint do
  @moduledoc """
  Compile-time capability linter for node bodies.

  A node's `pure_core` and `effect_shell` are ordinary Elixir, which means
  nothing in the language stops them from calling `File.write!/2`,
  `System.cmd/2`, `:httpc.request/4`, or `Req.get/1` directly — sidestepping the
  declared-capability facade (`ctx.effects.*`) entirely. This pass closes that
  gap: it walks the clause bodies and **rejects, at compile time, any call that
  reaches the world outside the facade**, so the facade is the only legal path
  to IO.

  ## What is allowed

  A remote call `M.f(...)` in a node body is permitted iff `M` is:

  1. the effect facade (`Bloccs.Effects.HTTP/DB/Time/Random`) — `effect_shell`
     only; `pure_core` must be side-effect-free, so the facade is rejected there;
  2. a curated, known-pure stdlib module (`Enum`, `Map`, `String`, `Date`, …);
  3. `Application` for read-only config (its mutators are denied);
  4. a module in this node's own OTP application (resolves local helpers), or
     sharing the node module's top-level namespace;
  5. a module explicitly listed in the manifest's `[lint] allow`.

  Everything else world-touching is a `CompileError`. Dynamic dispatch
  (`apply/3`, a call on a variable module, captures of denied modules) is
  rejected because it is not statically analyzable. Process/messaging escapes
  (`spawn`, `send`, `receive`, `Process.*`, `Task.*`) are rejected — concurrency
  is the generated supervision tree's job, not a node body's.

  ## Honest scope (the TCB)

  The trusted computing base is this pass plus the effect adapters. Within it the
  capability declaration is unbypassable for the restricted module surface. It is
  **not** a soundness proof: a too-permissive allow entry, a node calling its own
  app's `Repo` directly (allowed by rule 4), or a compromised dependency at
  runtime are out of scope. Runtime isolation remains OTP's job.

  ## Opting out

  `[lint] effects = "off"` downgrades violations to a single loud warning so a
  node with a vetted exception still compiles; the opt-out is recorded on the
  manifest and surfaced by tooling so the residual review stays visible.
  """

  alias Bloccs.Manifest.Lint

  @facade [
    Bloccs.Effects.HTTP,
    Bloccs.Effects.DB,
    Bloccs.Effects.Time,
    Bloccs.Effects.Random
  ]

  # Known-pure, IO-free modules a node body may call freely.
  @pure_stdlib MapSet.new([
                 Kernel,
                 Enum,
                 Map,
                 List,
                 String,
                 Integer,
                 Float,
                 Keyword,
                 Tuple,
                 MapSet,
                 Range,
                 Stream,
                 Date,
                 Time,
                 NaiveDateTime,
                 DateTime,
                 Calendar,
                 URI,
                 Base,
                 Bitwise,
                 Regex,
                 Access,
                 Atom,
                 Function,
                 Decimal,
                 Jason,
                 # pure Erlang. `:erlang` is here because the body AST is
                 # macro-expanded — operators like `==` / `or` / `++` become
                 # `:erlang.=:=` / `:erlang.orelse` / `:erlang.++`. The handful of
                 # genuinely effectful `:erlang` functions are denied in
                 # @deny_funs below.
                 :erlang,
                 :math,
                 :binary,
                 :lists,
                 :maps
               ])

  # Allowed, but read-only — mutators are listed in @deny_funs.
  @config_modules MapSet.new([Application])

  # World-touching modules, rejected with a guiding message.
  @deny_modules %{
    File => "direct file IO is outside the facade",
    IO => "direct IO is outside the facade",
    System => "shell / OS access is outside the facade",
    Code => "runtime code loading is outside the facade",
    Port => "ports are outside the facade",
    Process => "process operations are outside the facade",
    Task => "spawning tasks is outside the facade (the supervision tree owns concurrency)",
    GenServer => "stateful processes are outside the facade",
    Agent => "stateful processes are outside the facade",
    Node => "distribution is outside the facade",
    Logger => "logging is outside the facade (declare a log effect or [lint] allow)",
    Req => "HTTP must go through a declared `http` effect (ctx.effects.http)",
    HTTPoison => "HTTP must go through a declared `http` effect (ctx.effects.http)",
    Finch => "HTTP must go through a declared `http` effect (ctx.effects.http)",
    Tesla => "HTTP must go through a declared `http` effect (ctx.effects.http)",
    :os => "OS access is outside the facade",
    :file => "direct file IO is outside the facade",
    :httpc => "HTTP must go through a declared `http` effect (ctx.effects.http)",
    :inets => "HTTP must go through a declared `http` effect (ctx.effects.http)",
    :gen_tcp => "raw sockets are outside the facade",
    :ssl => "raw sockets are outside the facade",
    :ets => "ETS is outside the facade (use a declared `db` effect for state)",
    :dets => "DETS is outside the facade",
    :mnesia => "mnesia is outside the facade",
    :rpc => "distribution is outside the facade"
  }

  # Effectful functions on otherwise-permitted modules: ambient nondeterminism
  # and config mutation. Override the module-level allow.
  @deny_funs %{
    {DateTime, :utc_now} => "reading the wall clock is the `time` effect — use ctx.effects.time",
    {DateTime, :now} => "reading the wall clock is the `time` effect — use ctx.effects.time",
    {DateTime, :now!} => "reading the wall clock is the `time` effect — use ctx.effects.time",
    {NaiveDateTime, :utc_now} =>
      "reading the wall clock is the `time` effect — use ctx.effects.time",
    {NaiveDateTime, :local_now} =>
      "reading the wall clock is the `time` effect — use ctx.effects.time",
    {Date, :utc_today} => "reading the wall clock is the `time` effect — use ctx.effects.time",
    {Time, :utc_now} => "reading the wall clock is the `time` effect — use ctx.effects.time",
    {Application, :put_env} => "mutating app config is outside the facade",
    {Application, :delete_env} => "mutating app config is outside the facade",
    {Application, :start} => "starting apps is outside the facade",
    {Application, :stop} => "stopping apps is outside the facade",
    {Application, :ensure_all_started} => "starting apps is outside the facade",
    {Application, :ensure_started} => "starting apps is outside the facade",
    # Effectful `:erlang` BIFs (the module is otherwise allowed for operators).
    {:erlang, :spawn} => "spawning is outside the facade (the supervision tree owns concurrency)",
    {:erlang, :spawn_link} =>
      "spawning is outside the facade (the supervision tree owns concurrency)",
    {:erlang, :spawn_monitor} =>
      "spawning is outside the facade (the supervision tree owns concurrency)",
    {:erlang, :spawn_opt} =>
      "spawning is outside the facade (the supervision tree owns concurrency)",
    {:erlang, :send} => "message sends are outside the facade",
    {:erlang, :send_after} => "message sends are outside the facade",
    {:erlang, :open_port} => "ports are outside the facade",
    {:erlang, :halt} => "halting the VM is outside the facade",
    {:erlang, :apply} => "dynamic dispatch (apply) is not statically analyzable",
    {:erlang, :binary_to_term} => "deserializing terms is outside the facade",
    {:erlang, :system_time} => "reading the clock is the `time` effect — use ctx.effects.time",
    {:erlang, :monotonic_time} => "reading the clock is the `time` effect — use ctx.effects.time",
    {:erlang, :timestamp} => "reading the clock is the `time` effect — use ctx.effects.time",
    {:erlang, :now} => "reading the clock is the `time` effect — use ctx.effects.time"
  }

  # Imported (Kernel) / special-form names that escape the facade.
  @forbidden_locals %{
    send: "message sends are outside the facade (the supervision tree owns concurrency)",
    spawn: "spawning is outside the facade (the supervision tree owns concurrency)",
    spawn_link: "spawning is outside the facade (the supervision tree owns concurrency)",
    spawn_monitor: "spawning is outside the facade (the supervision tree owns concurrency)",
    apply: "dynamic dispatch (apply) is not statically analyzable — call the module directly"
  }

  @doc """
  Lint the clause `bodies` of one node function. `kind` is `:pure_core` or
  `:effect_shell`. `lint` is the manifest `[lint]` config (or `nil` → enforced
  with no extra allows). Raises `CompileError` on a violation when enforcing;
  emits a warning when opted out; returns `:ok` otherwise.
  """
  @spec lint(Macro.Env.t(), :pure_core | :effect_shell, [Macro.t()], Lint.t() | nil) :: :ok
  def lint(env, kind, bodies, lint) do
    enforce? = lint == nil or lint.enforce
    extra_allow = if lint, do: modules_from_strings(lint.allow), else: MapSet.new()

    ctx = %{
      kind: kind,
      env: env,
      app: app_of(env.module),
      ns: namespace_of(env.module),
      allow: extra_allow
    }

    violations =
      bodies
      |> Enum.flat_map(&scan(&1, ctx))
      |> Enum.uniq()

    cond do
      violations == [] ->
        :ok

      enforce? ->
        raise CompileError,
          file: env.file,
          description: format_violations(kind, violations)

      true ->
        IO.warn(
          "bloccs: capability linter is OFF for this node ([lint] effects = \"off\"). " <>
            "Read it — the following bypass the effect facade:\n" <>
            format_violations(kind, violations),
          env
        )

        :ok
    end
  end

  # ---- walker ----

  defp scan(body, ctx) do
    {_ast, acc} = Macro.prewalk(body, [], fn node, acc -> {node, check(node, ctx) ++ acc} end)
    acc
  end

  # Remote call with an Elixir-alias module head: `Mod.fun(args)`.
  defp check({{:., _, [{:__aliases__, _, _} = aliased, fun]}, meta, _args}, ctx)
       when is_atom(fun) do
    module = expand_module(aliased, ctx.env)
    verdict(module, fun, meta, ctx)
  end

  # Remote call with an Erlang atom module head: `:mod.fun(args)`.
  defp check({{:., _, [mod, fun]}, meta, _args}, ctx)
       when is_atom(mod) and is_atom(fun) do
    verdict(mod, fun, meta, ctx)
  end

  # Dynamic dispatch: module position is an expression (variable, etc.) — the
  # earlier clauses already handled alias and atom heads. The capability chain
  # `ctx.effects.http` is a no-paren property access (args == [] and no_parens),
  # which is data, not a dispatch, so it is left alone.
  defp check({{:., _, [_head, fun]}, meta, args}, _ctx) when is_atom(fun) do
    if args == [] and Keyword.get(meta, :no_parens) == true do
      []
    else
      [{line(meta), "dynamic dispatch on a computed module is not statically analyzable"}]
    end
  end

  # Imported / special-form escapes.
  defp check({name, meta, args}, _ctx)
       when is_map_key(@forbidden_locals, name) and is_list(args) do
    [{line(meta), Map.fetch!(@forbidden_locals, name)}]
  end

  defp check({:receive, meta, _}, _ctx) do
    [
      {line(meta),
       "receive blocks are outside the facade (the supervision tree owns concurrency)"}
    ]
  end

  defp check(_node, _ctx), do: []

  # ---- classification ----

  defp verdict(module, fun, meta, ctx) do
    cond do
      # Ambient nondeterminism / config mutation: denied even on otherwise-allowed
      # modules and not overridable by [lint] allow — these are determinism
      # guarantees, not a module-surface question.
      Map.has_key?(@deny_funs, {module, fun}) ->
        [{line(meta), "#{inspect(module)}.#{fun}: #{Map.fetch!(@deny_funs, {module, fun})}"}]

      # Author's explicit opt-in wins over the module denylist.
      MapSet.member?(ctx.allow, module) ->
        []

      module in @facade ->
        if ctx.kind == :effect_shell do
          []
        else
          [
            {line(meta),
             "pure_core must be side-effect-free; #{inspect(module)} is an effect facade — " <>
               "move this call to effect_shell"}
          ]
        end

      Map.has_key?(@deny_modules, module) ->
        [{line(meta), "#{inspect(module)}.#{fun}: #{Map.fetch!(@deny_modules, module)}"}]

      MapSet.member?(@pure_stdlib, module) ->
        []

      MapSet.member?(@config_modules, module) ->
        []

      same_app?(module, ctx) or same_namespace?(module, ctx) ->
        []

      # Exception construction (`raise Foo` expands to `Foo.exception/1`) is pure
      # control flow, allowed regardless of the exception module.
      fun in [:exception, :message] ->
        []

      true ->
        [
          {line(meta),
           "#{inspect(module)}.#{fun} is outside the permitted set (effect facade + pure " <>
             "stdlib + this app). If it is vetted and pure, add it to [lint] allow."}
        ]
    end
  end

  # ---- helpers ----

  defp expand_module({:__aliases__, _, parts} = aliased, env) do
    Macro.expand(aliased, env)
  rescue
    _ -> Module.concat(parts)
  end

  defp app_of(module) do
    Code.ensure_loaded?(module)
    Application.get_application(module)
  end

  defp same_app?(module, %{app: app}) when not is_nil(app) and is_atom(module) do
    Code.ensure_loaded?(module)
    Application.get_application(module) == app
  end

  defp same_app?(_module, _ctx), do: false

  defp namespace_of(module) do
    case safe_split(module) do
      [head | _] -> head
      _ -> nil
    end
  end

  defp same_namespace?(module, %{ns: ns}) when not is_nil(ns) do
    match?([^ns | _], safe_split(module))
  end

  defp same_namespace?(_module, _ctx), do: false

  defp safe_split(module) when is_atom(module) do
    Module.split(module)
  rescue
    # Erlang atom modules (e.g. :os) aren't Elixir modules and can't be split.
    ArgumentError -> []
  end

  defp modules_from_strings(names) do
    names
    |> Enum.map(&Module.concat([&1]))
    |> MapSet.new()
  end

  defp line(meta), do: Keyword.get(meta, :line, 0)

  defp format_violations(kind, violations) do
    lines =
      violations
      |> Enum.sort()
      |> Enum.map(fn {l, msg} -> "  - line #{l}: #{msg}" end)
      |> Enum.join("\n")

    "bloccs: #{kind} reaches the world outside the declared-capability facade.\n" <>
      lines <>
      "\n\nNode bodies may only touch the world through declared effects " <>
      "(ctx.effects.http / .db / .time / .random). " <>
      "If a call is intentional and vetted, add the module to `[lint] allow`, " <>
      "or set `[lint]\\n effects = \"off\"` to opt this node out (it will be flagged for review)."
  end
end
