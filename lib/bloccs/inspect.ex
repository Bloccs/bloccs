defmodule Bloccs.Inspect do
  @moduledoc """
  Opt-in capture of message payloads for observability (e.g. the `bloccs_web`
  Messages feed).

  **Off by default.** Payloads can be large or sensitive, so capture is enabled
  explicitly and is always bounded and redactable:

      config :bloccs, :inspect,
        enabled: true,
        max_bytes: 512,
        redact: [:password, :token, :secret, :authorization]

  When enabled, the runtime attaches a rendered, truncated, redacted snapshot of
  the emitted payload to the `[:bloccs, :emit]` telemetry event under the
  `:payload` metadata key (`nil` when disabled). It is a **string** — a display
  artifact, never the live term — so consumers can't accidentally hold or mutate
  message data.

  Redaction matches map keys by name (atom or string form) at any depth and
  replaces the value with `"[redacted]"`; structs keep their type.
  """

  @default [enabled: false, max_bytes: 512, redact: []]

  @type config :: [enabled: boolean(), max_bytes: pos_integer(), redact: [atom()]]

  @doc "The effective inspect config (application env merged over defaults)."
  @spec config() :: config()
  def config, do: Keyword.merge(@default, Application.get_env(:bloccs, :inspect, []))

  @doc "Whether payload capture is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: config()[:enabled] == true

  @doc """
  Render a bounded, redacted snapshot of `payload` for telemetry, or `nil` when
  capture is disabled. Always returns a string (or `nil`).
  """
  @spec capture(term()) :: String.t() | nil
  def capture(payload) do
    cfg = config()
    if cfg[:enabled], do: render(payload, cfg), else: nil
  end

  # ---- internals ----

  defp render(payload, cfg) do
    max = cfg[:max_bytes]

    payload
    |> redact(redact_set(cfg[:redact]))
    |> inspect(limit: :infinity, printable_limit: max, pretty: false)
    |> truncate(max)
  end

  defp redact_set(keys) do
    keys
    |> List.wrap()
    |> Enum.flat_map(fn k -> [k, to_string(k)] end)
    |> MapSet.new()
  end

  defp redact(%{__struct__: mod} = struct, keys) do
    struct(mod, struct |> Map.from_struct() |> redact_map(keys))
  end

  defp redact(map, keys) when is_map(map), do: redact_map(map, keys)
  defp redact(list, keys) when is_list(list), do: Enum.map(list, &redact(&1, keys))

  defp redact({a, b}, keys), do: {redact(a, keys), redact(b, keys)}
  defp redact(other, _keys), do: other

  defp redact_map(map, keys) do
    Map.new(map, fn {k, v} ->
      if MapSet.member?(keys, k), do: {k, "[redacted]"}, else: {k, redact(v, keys)}
    end)
  end

  defp truncate(string, max) do
    if String.length(string) > max, do: String.slice(string, 0, max) <> "…", else: string
  end
end
