defmodule Bloccs.Effects.Time.System do
  @moduledoc "Wall-clock time effect."

  defstruct mode: :wall_clock

  def new(mode) when is_binary(mode), do: %__MODULE__{mode: String.to_atom(mode)}
  def new(_), do: %__MODULE__{}

  def now(%__MODULE__{mode: :wall_clock}), do: DateTime.utc_now()

  def now(%__MODULE__{} = t),
    do: Bloccs.Effects.deny!(:time, "mode #{inspect(t.mode)} unsupported")
end
