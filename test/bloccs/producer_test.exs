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

  describe "bounded buffer" do
    test "drops messages past the buffer and emits an overflow telemetry event" do
      name = :"prod_buf_#{:erlang.unique_integer([:positive, :monotonic])}"
      # No consumer → demand stays 0 → pushed items sit in the queue.
      {:ok, pid} = Producer.start_link(name: name, buffer: 2)
      on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)

      test_pid = self()
      handler = "overflow-#{name}"

      :telemetry.attach(
        handler,
        [:bloccs, :producer, :overflow],
        fn _event, meas, meta, _ -> send(test_pid, {:overflow, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      :ok = Producer.push(name, %{n: 1})
      :ok = Producer.push(name, %{n: 2})
      # third exceeds buffer=2 → dropped
      :ok = Producer.push(name, %{n: 3})

      assert_receive {:overflow, %{dropped: 1, size: 2}, %{name: ^name, buffer: 2}}, 500

      # Attaching a consumer now drains exactly the two buffered items.
      {:ok, _consumer} = Sink.start_link(pid, self())
      assert_receive {:got, %{n: 1}}, 500
      assert_receive {:got, %{n: 2}}, 500
      refute_receive {:got, %{n: 3}}, 100
    end

    test "an unbounded producer (buffer: nil) never drops" do
      name = :"prod_unbounded_#{:erlang.unique_integer([:positive, :monotonic])}"
      {:ok, pid} = Producer.start_link(name: name, buffer: nil)
      on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)

      for n <- 1..50, do: :ok = Producer.push(name, %{n: n})

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
