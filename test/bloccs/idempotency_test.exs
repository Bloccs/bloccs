defmodule Bloccs.IdempotencyTest do
  @moduledoc "Unit coverage for the idempotency key tracker."

  use ExUnit.Case, async: false

  alias Bloccs.Idempotency

  setup do
    Idempotency.reset()
    on_exit(&Idempotency.reset/0)
    :ok
  end

  test "an unseen key is not seen; marking makes it seen" do
    scope = {:net, :node}

    refute Idempotency.seen?(scope, "r1")
    assert :ok = Idempotency.mark(scope, "r1")
    assert Idempotency.seen?(scope, "r1")
  end

  test "keys are scoped per {network, node}" do
    Idempotency.mark({:net, :a}, "r1")

    assert Idempotency.seen?({:net, :a}, "r1")
    refute Idempotency.seen?({:net, :b}, "r1")
    refute Idempotency.seen?({:other, :a}, "r1")
  end

  test "distinct key values within a scope are independent" do
    Idempotency.mark({:net, :node}, "r1")

    assert Idempotency.seen?({:net, :node}, "r1")
    refute Idempotency.seen?({:net, :node}, "r2")
  end

  test "reset clears everything" do
    Idempotency.mark({:net, :node}, "r1")
    Idempotency.reset()
    refute Idempotency.seen?({:net, :node}, "r1")
  end
end
