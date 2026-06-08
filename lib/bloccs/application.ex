defmodule Bloccs.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Bloccs.Registry},
      # Running networks register themselves here at boot (see Bloccs.Discovery)
      # so introspection tools can enumerate them without scanning the tree.
      {Registry, keys: :unique, name: Bloccs.NetworkRegistry},
      Bloccs.Idempotency,
      Bloccs.Router,
      Bloccs.Join,
      # Correlates a network's reply back to a `Bloccs.call/4` / `cast/4` caller.
      Bloccs.Collector
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Bloccs.Supervisor)
  end
end
