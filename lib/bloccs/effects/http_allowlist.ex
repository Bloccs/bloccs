defmodule Bloccs.Effects.HTTP.Allowlist do
  @moduledoc """
  Shared host/method allowlist enforcement for HTTP backends.

  Both the mock and the real (`Req`) backend run this *before* any I/O, so the
  capability guarantee — a node can only reach hosts/methods it declared in
  `[effects].http` — holds identically regardless of backend.
  """

  @doc """
  Check a `method` + `url` against the declared `allow` hosts and `methods`.
  Returns `:ok` or `{:deny, detail}` with a human-readable reason.
  """
  @spec check([String.t()], [String.t()], String.t(), String.t()) :: :ok | {:deny, String.t()}
  def check(allow, methods, method, url) do
    cond do
      not method_allowed?(methods, method) ->
        {:deny, "method #{method} not in declared methods #{inspect(methods)}"}

      not host_allowed?(allow, url) ->
        {:deny, "host of #{url} not in declared allowlist #{inspect(allow)}"}

      true ->
        :ok
    end
  end

  defp method_allowed?(methods, method),
    do: Enum.any?(methods, &(String.upcase(&1) == String.upcase(method)))

  defp host_allowed?(allow, url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host in allow
      _ -> false
    end
  end
end
