defmodule Tour.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Register every rung's port schemas before any message flows.
    Tour.Schemas.register()

    Supervisor.start_link([], strategy: :one_for_one, name: Tour.Supervisor)
  end
end
