defmodule Bloccs.Effects.Time.System do
  @moduledoc "Wall-clock time effect."

  @behaviour Bloccs.Effects.Time

  defstruct mode: :wall_clock

  @impl true
  def new(mode) when is_binary(mode), do: %__MODULE__{mode: String.to_atom(mode)}
  def new(_), do: %__MODULE__{}

  @impl true
  def now(%__MODULE__{mode: :wall_clock}), do: DateTime.utc_now()

  def now(%__MODULE__{} = t),
    do: Bloccs.Effects.deny!(:time, "mode #{inspect(t.mode)} unsupported")
end
