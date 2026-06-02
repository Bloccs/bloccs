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

  describe "reserve/2 + release/2" do
    test "reserve is atomic: only the first caller wins" do
      assert Idempotency.reserve({:net, :node}, "k") == true
      assert Idempotency.reserve({:net, :node}, "k") == false
      assert Idempotency.reserve({:net, :node}, "k") == false
    end

    test "reserving makes the key seen" do
      Idempotency.reserve({:net, :node}, "k")
      assert Idempotency.seen?({:net, :node}, "k")
    end

    test "release frees a reserved key so it can be reserved again" do
      assert Idempotency.reserve({:net, :node}, "k") == true
      assert :ok = Idempotency.release({:net, :node}, "k")
      refute Idempotency.seen?({:net, :node}, "k")
      assert Idempotency.reserve({:net, :node}, "k") == true
    end

    test "concurrent reservations of one key yield exactly one winner" do
      parent = self()

      for _ <- 1..20,
          do: spawn(fn -> send(parent, {:won?, Idempotency.reserve({:net, :race}, "k")}) end)

      results = for _ <- 1..20, do: receive(do: ({:won?, w} -> w))
      assert Enum.count(results, & &1) == 1
    end
  end
end
