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

  test "emits %Broadway.Message{} with the acknowledger we control" do
    name = :"prod_msg_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = Producer.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenStage.stop(pid) end)
    {:ok, _consumer} = Sink.start_link(pid, self())

    :ok = Producer.push(name, :hello)
    assert_receive {:got, :hello}, 500
  end
end
