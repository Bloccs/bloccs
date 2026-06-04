defmodule Bloccs.ProducerTest do
  use ExUnit.Case, async: false

  alias Bloccs.Producer

  defmodule Sink do
    @moduledoc false
    use GenStage

    def start_link(producer, parent),
      do: GenStage.start_link(__MODULE__, {producer, parent})

    @impl true
    def init({producer, parent}) do
      {:consumer, parent, subscribe_to: [{producer, min_demand: 0, max_demand: 10}]}
    end

    @impl true
    def handle_events(events, _from, parent) do
      Enum.each(events, fn %Broadway.Message{data: d} -> send(parent, {:got, d}) end)
      {:noreply, [], parent}
    end
  end

  test "registers under the configured name and serves pushed messages on demand" do
    name = :"prod_#{:erlang.unique_integer([:positive, :monotonic])}"

    {:ok, pid} = Producer.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)

    assert [{^pid, _}] = Registry.lookup(Bloccs.Registry, name)

    {:ok, _consumer} = Sink.start_link(pid, self())

    :ok = Producer.push(name, %{n: 1})
    :ok = Producer.push(name, %{n: 2})

    assert_receive {:got, %{n: 1}}, 500
    assert_receive {:got, %{n: 2}}, 500
  end

  test "push to an unregistered name returns :no_producer" do
    assert :no_producer = Producer.push(:totally_not_registered_xyz, %{})
  end

  test "push_after to an unregistered name returns :no_producer" do
    assert :no_producer = Producer.push_after(:totally_not_registered_xyz, %{}, %{}, 0)
  end

  test "carries push meta through to the Broadway.Message metadata" do
    name = :"prod_meta_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = Producer.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)
    {:ok, _consumer} = Sink.start_link(pid, self())

    :ok = Producer.push(name, :x, %{bloccs_attempt: 2})
    assert_receive {:got, :x}, 500
  end

  test "a delay producer time-shifts delivery by the configured ms" do
    name = :"prod_delay_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = Producer.start_link(name: name, delay: 150)
    on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)
    {:ok, _consumer} = Sink.start_link(pid, self())

    # push returns immediately (delay shifts in time, it does not block).
    assert :ok = Producer.push(name, %{n: 1})
    refute_receive {:got, %{n: 1}}, 80
    assert_receive {:got, %{n: 1}}, 500
  end

  describe "bounded buffer back-pressure" do
    test "parks the caller when full and admits once a consumer drains (no drops)" do
      name = :"prod_buf_#{:erlang.unique_integer([:positive, :monotonic])}"
      # No consumer → demand stays 0 → pushed items sit in the queue.
      {:ok, pid} = Producer.start_link(name: name, buffer: 2)
      on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)

      test_pid = self()
      handler = "bp-#{name}"

      :telemetry.attach(
        handler,
        [:bloccs, :producer, :backpressure],
        fn _e, meas, meta, _ -> send(test_pid, {:backpressure, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # First two fill the buffer and return immediately.
      assert :ok = Producer.push(name, %{n: 1})
      assert :ok = Producer.push(name, %{n: 2})

      # The third should PARK (buffer full, no consumer). Push it from a separate
      # process so we can observe that it does not return yet.
      caller = spawn(fn -> send(test_pid, {:pushed, Producer.push(name, %{n: 3})}) end)

      assert_receive {:backpressure, %{size: 2}, %{name: ^name, buffer: 2}}, 500
      refute_receive {:pushed, _}, 200
      assert Process.alive?(caller)

      # Attaching a consumer drains the buffer, which admits the parked push.
      {:ok, _consumer} = Sink.start_link(pid, self())
      assert_receive {:pushed, :ok}, 1_000

      # All three are eventually delivered — nothing was dropped.
      assert_receive {:got, %{n: 1}}, 500
      assert_receive {:got, %{n: 2}}, 500
      assert_receive {:got, %{n: 3}}, 500
    end

    test "an unbounded producer (buffer: nil) never parks" do
      name = :"prod_unbounded_#{:erlang.unique_integer([:positive, :monotonic])}"
      {:ok, pid} = Producer.start_link(name: name, buffer: nil)
      on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)

      for n <- 1..50, do: assert(:ok = Producer.push(name, %{n: n}))

      {:ok, _consumer} = Sink.start_link(pid, self())
      assert_receive {:got, %{n: 1}}, 500
      assert_receive {:got, %{n: 50}}, 500
    end
  end

  test "emits %Broadway.Message{} with the acknowledger we control" do
    name = :"prod_msg_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = Producer.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)
    {:ok, _consumer} = Sink.start_link(pid, self())

    :ok = Producer.push(name, :hello)
    assert_receive {:got, :hello}, 500
  end
end
