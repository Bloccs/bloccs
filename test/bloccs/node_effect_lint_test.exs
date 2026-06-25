defmodule Bloccs.Node.EffectLintTest do
  @moduledoc """
  Drives `Bloccs.Node.EffectLint` directly with quoted node-body ASTs, the same
  shape the `@after_compile` hook feeds it from `Module.get_definition/2`. The
  env is this test module's `__ENV__`, so `env.module` belongs to the `:bloccs`
  application — exercising the same-app allow rule.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Bloccs.Manifest.Lint
  alias Bloccs.Node.EffectLint

  @env __ENV__

  defp lint(kind, body, opts \\ []) do
    EffectLint.lint(@env, kind, [body], Keyword.get(opts, :lint))
  end

  defp refute_lint(kind, body, opts \\ []) do
    assert lint(kind, body, opts) == :ok
  end

  defp assert_rejects(kind, body, expect \\ nil) do
    err =
      assert_raise CompileError, fn ->
        # capture_io so the (expected) error text doesn't clutter test output
        capture_io(:stderr, fn -> lint(kind, body) end)
      end

    if expect, do: assert(err.description =~ expect)
    err
  end

  describe "rejects direct world access (the bypass the reviewer named)" do
    test "File.write! in effect_shell" do
      assert_rejects(:effect_shell, quote(do: File.write!("/tmp/x", data)), "direct file IO")
    end

    test "System.cmd in pure_core" do
      assert_rejects(:pure_core, quote(do: System.cmd("curl", [url])), "shell / OS access")
    end

    test "Req.get is steered to the http effect" do
      assert_rejects(:effect_shell, quote(do: Req.get("http://x")), "ctx.effects.http")
    end

    test ":httpc.request (Erlang) is rejected" do
      assert_rejects(:effect_shell, quote(do: :httpc.request(:get, req, [], [])))
    end

    test ":ets is steered to the db effect" do
      assert_rejects(:effect_shell, quote(do: :ets.insert(:tab, {k, v})), "db` effect")
    end
  end

  describe "rejects unanalyzable / process escapes" do
    test "apply/3 dynamic dispatch" do
      assert_rejects(:pure_core, quote(do: apply(File, :write!, [p, d])), "apply")
    end

    test "capture of a denied module &File.write!/2" do
      assert_rejects(:pure_core, quote(do: Enum.each(xs, &File.write!/2)), "direct file IO")
    end

    test "call on a computed module" do
      assert_rejects(:pure_core, quote(do: mod.run(payload)), "dynamic dispatch")
    end

    test "send/2" do
      assert_rejects(:effect_shell, quote(do: send(pid, :go)), "message sends")
    end

    test "spawn/1" do
      assert_rejects(:effect_shell, quote(do: spawn(fn -> work() end)), "spawning")
    end

    test "receive block" do
      body =
        quote(
          do:
            receive do
              x -> x
            end
        )

      assert_rejects(:effect_shell, body, "receive")
    end
  end

  describe "ambient nondeterminism is the time/random effect" do
    test "DateTime.utc_now/0" do
      assert_rejects(:pure_core, quote(do: DateTime.utc_now()), "ctx.effects.time")
    end

    test "DateTime arithmetic is pure and allowed" do
      refute_lint(:pure_core, quote(do: DateTime.add(dt, 1, :second)))
    end

    test ":rand is steered to the random effect" do
      assert_rejects(:effect_shell, quote(do: :rand.uniform(10)), "ctx.effects.random")
    end

    test ":erlang.unique_integer (ambient) is rejected" do
      assert_rejects(
        :pure_core,
        quote(do: :erlang.unique_integer([:monotonic])),
        "nondeterminism"
      )
    end

    test "make_ref is rejected (a pure core must be deterministic)" do
      assert_rejects(:pure_core, quote(do: make_ref()), "deterministic")
    end
  end

  describe "the facade is allowed in effect_shell, not pure_core" do
    test "Bloccs.Effects.HTTP in effect_shell compiles clean" do
      refute_lint(
        :effect_shell,
        quote(do: Bloccs.Effects.HTTP.post(ctx.effects.http, "u", body))
      )
    end

    test "the capability chain ctx.effects.http is data, not a dispatch" do
      refute_lint(:effect_shell, quote(do: ctx.effects.http))
    end

    test "the facade in pure_core is rejected" do
      assert_rejects(
        :pure_core,
        quote(do: Bloccs.Effects.DB.insert(ctx.effects.db, :t, a)),
        "side-effect-free"
      )
    end
  end

  describe "pure stdlib and same-app calls are allowed" do
    test "Enum / Map / String" do
      refute_lint(:pure_core, quote(do: Enum.map(xs, &String.trim/1)))
      refute_lint(:pure_core, quote(do: Map.put(m, :k, v)))
    end

    test "operators (expand to :erlang BIFs) are fine" do
      refute_lint(:pure_core, quote(do: a == b and c ++ d))
    end

    test "Application.get_env (sanctioned config read)" do
      refute_lint(:pure_core, quote(do: Application.get_env(:price_watch, :port, 4011)))
    end

    test "Application.put_env (config mutation) is rejected" do
      assert_rejects(:pure_core, quote(do: Application.put_env(:a, :b, 1)), "mutating app config")
    end

    test "a sibling module in the same OTP app is allowed" do
      refute_lint(:pure_core, quote(do: Bloccs.Parser.parse_node_string("x")))
    end
  end

  describe "the [lint] escape hatch" do
    test "effects = \"off\" downgrades to a warning and still compiles" do
      off = %Lint{enforce: false, allow: []}

      captured =
        capture_io(:stderr, fn ->
          assert lint(:effect_shell, quote(do: File.write!("/x", d)), lint: off) == :ok
        end)

      assert captured =~ "capability linter is OFF"
      assert captured =~ "direct file IO"
    end

    test "allow = [..] permits a specific vetted module" do
      allow = %Lint{enforce: true, allow: ["My.Vetted.Lib"]}
      refute_lint(:pure_core, quote(do: My.Vetted.Lib.transform(x)), lint: allow)
    end
  end
end
