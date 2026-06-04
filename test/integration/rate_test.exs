defmodule Bloccs.Integration.RateTest do
  @moduledoc """
  Proves the throttle (`[rate]`) and delay (`[delay]`) manifest blocks reach the
  generated producer config — `[rate]` as Broadway `rate_limiting`, `[delay]` as
  a `Bloccs.Producer` delay option — and that messages still flow through such a
  node. (Precise delay timing is covered by `Bloccs.ProducerTest`.)
  """

  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Producer, Router, Schema, Validator}

  @path Path.expand("../fixtures/rate/rate.bloccs", __DIR__)

  setup_all do
    Schema.clear!()
    Schema.register("X@1", n: :integer)

    {:ok, network} = Parser.parse_network(@path)
    :ok = Validator.validate_network(network)
    {:ok, sup} = Compiler.compile_and_load(network)
    {:ok, _} = sup.start_link([])

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  test "the compiler emits rate_limiting and a producer delay" do
    [src] = Path.wildcard("_build/#{Mix.env()}/bloccs_generated/rate/nodes/limited.ex")
    source = File.read!(src)

    assert source =~ "rate_limiting: [allowed_messages: 10, interval: 1000]"
    assert source =~ "delay: 50"
  end

  test "messages still flow through a throttled + delayed node" do
    Router.register_sink(:rate, :rate_sink, :out, self())

    :ok = Producer.push(Router.producer_name(:rate, :limited, :inp), %{"n" => 1})

    assert_receive {:bloccs_sink, :rate, :rate_sink, :out, %{"n" => 1}}, 1_000
  end
end
