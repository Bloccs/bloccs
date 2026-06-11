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

  Redirects are followed manually (Req's auto-redirect is disabled) so that
  **every hop is re-checked against the allowlist** — a declared host that
  redirects to an undeclared one (e.g. a cloud metadata address) is denied,
  not followed. At most 10 redirects are followed; beyond that the call
  resolves to `{:error, {:too_many_redirects, url}}`.

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
    unless Code.ensure_loaded?(Req) do
      raise """
      Bloccs.Effects.HTTP.Req requires the optional :req dependency, which is not \
      available. Add it to your application's deps to use the real HTTP backend:

          {:req, "~> 0.5"}

      (or select a different http backend in config :bloccs, :effect_backends).
      """
    end

    %__MODULE__{allow: allow, methods: methods, options: configured_options()}
  end

  @impl true
  def post(%__MODULE__{} = cap, url, body), do: request(cap, "POST", url, json: body)

  @impl true
  def get(%__MODULE__{} = cap, url), do: request(cap, "GET", url, [])

  @max_redirects 10
  @redirect_statuses [301, 302, 303, 307, 308]

  defp request(%__MODULE__{allow: allow, methods: methods, options: opts}, method, url, req_opts) do
    case Allowlist.check(allow, methods, method, url) do
      :ok ->
        run({allow, methods}, method, url, Keyword.merge(opts, req_opts), @max_redirects)

      {:deny, detail} ->
        Effects.deny!(:http, detail)
    end
  end

  # Req's built-in redirect step would follow a 302 to any host, silently
  # escaping the allowlist — so auto-redirect is forced off and each hop is
  # re-checked here before it is requested.
  defp run(decl, method, url, opts, redirects_left) do
    verb = method |> String.downcase() |> String.to_existing_atom()

    case apply(Req, verb, [url, Keyword.put(opts, :redirect, false)]) do
      {:ok, %{status: status} = resp} when status in @redirect_statuses ->
        follow_redirect(decl, method, url, resp, opts, redirects_left)

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        ok_body(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_redirect(_decl, _method, url, _resp, _opts, 0),
    do: {:error, {:too_many_redirects, url}}

  defp follow_redirect({allow, methods} = decl, method, url, resp, opts, redirects_left) do
    case location(resp) do
      nil ->
        {:error, {:http_status, resp.status, resp.body}}

      location ->
        next_url = url |> URI.merge(location) |> URI.to_string()
        {next_method, next_opts} = redirect_method(resp.status, method, opts)

        case Allowlist.check(allow, methods, next_method, next_url) do
          :ok -> run(decl, next_method, next_url, next_opts, redirects_left - 1)
          {:deny, detail} -> Effects.deny!(:http, "redirect denied: #{detail}")
        end
    end
  end

  # 303 — and, per long-standing client behavior, 301/302 on a non-GET —
  # downgrade to a body-less GET; 307/308 preserve method and body.
  defp redirect_method(status, method, opts) when status in [301, 302, 303] and method != "GET",
    do: {"GET", Keyword.delete(opts, :json)}

  defp redirect_method(_status, method, opts), do: {method, opts}

  defp location(%{headers: headers}) do
    case Map.get(headers, "location") do
      [loc | _] -> loc
      loc when is_binary(loc) -> loc
      _ -> nil
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
