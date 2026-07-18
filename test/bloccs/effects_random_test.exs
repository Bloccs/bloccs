defmodule Bloccs.EffectsRandomTest do
  use ExUnit.Case, async: true

  alias Bloccs.Effects.Random.System, as: RandomSystem

  test "pseudo mode draws in 1..n" do
    cap = RandomSystem.new("pseudo")

    for _ <- 1..100 do
      assert RandomSystem.int(cap, 10) in 1..10
    end
  end

  test "crypto mode draws from :crypto, uniformly in 1..n" do
    cap = RandomSystem.new("crypto")

    draws = for _ <- 1..300, do: RandomSystem.int(cap, 4)

    assert Enum.all?(draws, &(&1 in 1..4))
    # All four values should appear across 300 draws (P(miss) ≈ 4 × 0.75^300).
    assert draws |> Enum.uniq() |> Enum.sort() == [1, 2, 3, 4]
  end

  test "crypto mode handles n = 1 and large n" do
    cap = RandomSystem.new("crypto")

    assert RandomSystem.int(cap, 1) == 1

    big = 1_000_000_000_000
    assert RandomSystem.int(cap, big) in 1..big
  end

  test "an unrecognized mode is denied on use without minting an atom" do
    mode = "definitely-not-a-mode-#{:erlang.unique_integer([:positive])}"
    cap = RandomSystem.new(mode)

    # The unknown mode must be kept as a binary, never interned as an atom.
    # Assert on *this specific name* rather than the global atom_count, which
    # races against every other async test that legitimately mints an atom.
    assert_raise ArgumentError, fn -> String.to_existing_atom(mode) end

    assert_raise Bloccs.Effects.Denied, ~r/unsupported/, fn ->
      RandomSystem.int(cap, 10)
    end
  end
end
