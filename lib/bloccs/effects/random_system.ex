defmodule Bloccs.Effects.Random.System do
  @moduledoc """
  Pseudo / crypto random effect.

  `random = "pseudo"` draws from `:rand` (fast, not suitable for secrets);
  `random = "crypto"` draws from `:crypto.strong_rand_bytes/1` via unbiased
  rejection sampling, suitable for tokens and nonces.
  """

  @behaviour Bloccs.Effects.Random

  defstruct mode: :pseudo

  @impl true
  def new("pseudo"), do: %__MODULE__{mode: :pseudo}
  def new("crypto"), do: %__MODULE__{mode: :crypto}
  # An unrecognized mode is kept verbatim (no atom minted from manifest input)
  # and denied on first use with the original string in the message.
  def new(mode) when is_binary(mode), do: %__MODULE__{mode: mode}
  def new(_), do: %__MODULE__{mode: :pseudo}

  @impl true
  def int(%__MODULE__{mode: :pseudo}, n) when is_integer(n) and n > 0, do: :rand.uniform(n)

  def int(%__MODULE__{mode: :crypto}, n) when is_integer(n) and n > 0, do: crypto_uniform(n)

  def int(%__MODULE__{mode: mode}, _),
    do: Bloccs.Effects.deny!(:random, "mode #{inspect(mode)} unsupported")

  # Uniform 1..n from strong random bytes. A bare `rem(r, n)` is modulo-biased
  # whenever 256^bytes isn't a multiple of n, so values past the largest exact
  # multiple of n are rejected and redrawn.
  defp crypto_uniform(1), do: 1

  defp crypto_uniform(n) do
    bytes = byte_width(n)
    range = Integer.pow(256, bytes)
    threshold = range - rem(range, n)
    r = :crypto.bytes_to_integer(:crypto.strong_rand_bytes(bytes))

    if r < threshold, do: rem(r, n) + 1, else: crypto_uniform(n)
  end

  defp byte_width(n) do
    bits = (n - 1) |> Integer.digits(2) |> length()
    div(bits + 7, 8)
  end
end
