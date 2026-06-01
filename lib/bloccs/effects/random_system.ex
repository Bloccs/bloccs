defmodule Bloccs.Effects.Random.System do
  @moduledoc "Pseudo / crypto random effect."

  @behaviour Bloccs.Effects.Random

  defstruct mode: :pseudo

  @impl true
  def new(mode) when is_binary(mode), do: %__MODULE__{mode: String.to_atom(mode)}
  def new(_), do: %__MODULE__{mode: :pseudo}

  @impl true
  def int(%__MODULE__{mode: :pseudo}, n) when is_integer(n) and n > 0, do: :rand.uniform(n)

  def int(%__MODULE__{mode: :crypto}, n) when is_integer(n) and n > 0,
    do: :rand.uniform(n)

  def int(%__MODULE__{mode: mode}, _),
    do: Bloccs.Effects.deny!(:random, "mode #{inspect(mode)} unsupported")
end
