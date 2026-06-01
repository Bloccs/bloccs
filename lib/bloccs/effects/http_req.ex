defmodule Bloccs.Effects.HTTP.Req do
  @moduledoc """
  Real HTTP backend built on [Req](https://hexdocs.pm/req).

  Select it in production with:

      config :bloccs, :effect_backends, http: Bloccs.Effects.HTTP.Req

  The declared `[effects].http` allowlist is enforced by
  `Bloccs.Effects.HTTP.Allowlist` *before* any request leaves the VM — the same
  check the mock uses — so the capability guarantee is identical to test runs.
  A denied call raises `Bloccs.Effects.Denied` (caught by the runtime and turned
  into a failed message), matching the mock's behavior.

  Extra Req options (timeouts, retries, a test adapter/plug, auth headers) can
  be supplied globally:

      config :bloccs, Bloccs.Effects.HTTP.Req, req_options: [retry: :transient]

  Responses with a 2xx status resolve to `{:ok, body}` (a decoded JSON object is
  a map); non-2xx resolves to `{:error, {:http_status, status, body}}`; a
  transport failure to `{:error, exception}`.
  """

  @behaviour Bloccs.Effects.HTTP

  alias Bloccs.Effects
  alias Bloccs.Effects.HTTP.Allowlist

  defstruct allow: [], methods: [], options: []

  @type t :: %__MODULE__{allow: [String.t()], methods: [String.t()], options: keyword()}

  @impl true
  def new(%{allow: allow, methods: methods}) do
    %__MODULE__{allow: allow, methods: methods, options: configured_options()}
  end

  @impl true
  def post(%__MODULE__{} = cap, url, body), do: request(cap, "POST", url, json: body)

  @impl true
  def get(%__MODULE__{} = cap, url), do: request(cap, "GET", url, [])

  defp request(%__MODULE__{allow: allow, methods: methods, options: opts}, method, url, req_opts) do
    case Allowlist.check(allow, methods, method, url) do
      :ok -> run(method, url, Keyword.merge(opts, req_opts))
      {:deny, detail} -> Effects.deny!(:http, detail)
    end
  end

  defp run(method, url, opts) do
    verb = method |> String.downcase() |> String.to_existing_atom()

    case apply(Req, verb, [url, opts]) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> ok_body(body)
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ok_body(body) when is_map(body), do: {:ok, body}
  defp ok_body(body), do: {:ok, %{"body" => body}}

  defp configured_options do
    :bloccs
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
