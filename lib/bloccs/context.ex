defmodule Bloccs.Context do
  @moduledoc """
  The per-message context passed to a node's pure-core and effect-shell.

  Holds the effect capability struct (from `Bloccs.Effects.bind/1`), the
  wall-clock receipt time, and an arbitrary metadata bag for things like
  `request_id`, retries, telemetry tags.
  """

  alias Bloccs.Effects.Capabilities

  @type t :: %__MODULE__{
          effects: Capabilities.t(),
          received_at: DateTime.t(),
          meta: map()
        }

  @enforce_keys [:effects, :received_at]
  defstruct [:effects, :received_at, meta: %{}]

  @doc "Build a context. Accepts the same kw opts as the struct fields."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      effects: Keyword.fetch!(opts, :effects),
      received_at: Keyword.get(opts, :received_at, DateTime.utc_now()),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end
