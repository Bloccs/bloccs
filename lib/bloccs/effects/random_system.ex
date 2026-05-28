defmodule Bloccs.Effects.Random.System do
  @moduledoc "Pseudo / crypto random effect."

  defstruct mode: :pseudo

  def new(mode) when is_binary(mode), do: %__MODULE__{mode: String.to_atom(mode)}
  def new(_), do: %__MODULE__{mode: :pseudo}

  def int(%__MODULE__{mode: :pseudo}, n) when is_integer(n) and n > 0, do: :rand.uniform(n)

  def int(%__MODULE__{mode: :crypto}, n) when is_integer(n) and n > 0,
    do: :rand.uniform(n)

  def int(%__MODULE__{mode: mode}, _),
    do: Bloccs.Effects.deny!(:random, "mode #{inspect(mode)} unsupported")
end
