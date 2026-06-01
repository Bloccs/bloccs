defmodule Bloccs.RetryTest do
  @moduledoc "Pure decision coverage for the retry policy evaluator."

  use ExUnit.Case, async: true

  alias Bloccs.Retry

  defp policy(opts) do
    %{
      strategy: Keyword.get(opts, :strategy, "exponential"),
      max: Keyword.get(opts, :max, 3),
      on: Keyword.get(opts, :on, []),
      base_ms: Keyword.get(opts, :base_ms)
    }
  end

  describe "retriable?/3" do
    test "no policy → never retry" do
      refute Retry.retriable?(:timeout, nil, 0)
    end

    test "empty on-list retries any transient failure within max" do
      assert Retry.retriable?(:timeout, policy(on: []), 0)
      assert Retry.retriable?({:node_crash, :boom}, policy(on: []), 2)
    end

    test "stops once attempt reaches max" do
      assert Retry.retriable?(:timeout, policy(max: 3), 2)
      refute Retry.retriable?(:timeout, policy(max: 3), 3)
      refute Retry.retriable?(:timeout, policy(max: 0), 0)
    end

    test "non-empty on-list only retries listed tags" do
      pol = policy(on: ["timeout", "node_crash"])
      assert Retry.retriable?(:timeout, pol, 0)
      assert Retry.retriable?({:node_crash, :x}, pol, 0)
      refute Retry.retriable?(:something_else, pol, 0)
    end

    test "permanent failures are never retried even with a matching policy" do
      pol = policy(on: [])
      refute Retry.retriable?({:schema_mismatch, "S@1", ["bad"]}, pol, 0)
      refute Retry.retriable?({:unknown_port, :nope}, pol, 0)
      refute Retry.retriable?({:payload_not_map, "x"}, pol, 0)
      refute Retry.retriable?(%Bloccs.Effects.Denied{axis: :http, detail: "denied"}, pol, 0)
    end
  end

  describe "backoff_ms/2" do
    test "constant strategy is flat at base" do
      pol = policy(strategy: "constant", base_ms: 100)
      assert Retry.backoff_ms(pol, 0) == 100
      assert Retry.backoff_ms(pol, 5) == 100
    end

    test "linear grows with attempt" do
      pol = policy(strategy: "linear", base_ms: 100)
      assert Retry.backoff_ms(pol, 0) == 100
      assert Retry.backoff_ms(pol, 1) == 200
      assert Retry.backoff_ms(pol, 2) == 300
    end

    test "exponential doubles per attempt" do
      pol = policy(strategy: "exponential", base_ms: 100)
      assert Retry.backoff_ms(pol, 0) == 100
      assert Retry.backoff_ms(pol, 1) == 200
      assert Retry.backoff_ms(pol, 2) == 400
      assert Retry.backoff_ms(pol, 3) == 800
    end

    test "defaults base to 100ms when unset" do
      assert Retry.backoff_ms(policy(strategy: "constant", base_ms: nil), 0) == 100
    end

    test "caps at 30s" do
      pol = policy(strategy: "exponential", base_ms: 1000)
      assert Retry.backoff_ms(pol, 100) == 30_000
    end
  end

  describe "reason_tag/1" do
    test "atoms, tuples, exceptions, and other" do
      assert Retry.reason_tag(:timeout) == "timeout"
      assert Retry.reason_tag({:node_crash, :boom}) == "node_crash"
      assert Retry.reason_tag(%RuntimeError{message: "x"}) == "exception"
      assert Retry.reason_tag("weird") == "error"
    end
  end
end
