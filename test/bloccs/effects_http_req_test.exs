defmodule Bloccs.EffectsHTTPReqTest do
  @moduledoc """
  The real Req-backed HTTP adapter. A fake transport is injected via Req's
  `:adapter` option (configured through the backend's own config key), so no
  network or Plug stub is needed.
  """

  use ExUnit.Case, async: false

  alias Bloccs.Effects.HTTP.Req, as: ReqHTTP

  @decl %{allow: ["api.stripe.com"], methods: ["POST", "GET"]}

  defp with_adapter(fun) do
    Application.put_env(:bloccs, ReqHTTP, req_options: [adapter: fun])
    on_exit(fn -> Application.delete_env(:bloccs, ReqHTTP) end)
    ReqHTTP.new(@decl)
  end

  test "allowed POST with a 2xx response resolves to {:ok, body}" do
    cap =
      with_adapter(fn req ->
        {req, Req.Response.new(status: 200, body: %{"id" => "ch_req", "status" => "succeeded"})}
      end)

    assert {:ok, %{"id" => "ch_req", "status" => "succeeded"}} =
             ReqHTTP.post(cap, "https://api.stripe.com/v1/charges", %{amount: 100})
  end

  test "a non-2xx status resolves to {:error, {:http_status, status, body}}" do
    cap =
      with_adapter(fn req ->
        {req, Req.Response.new(status: 422, body: %{"error" => "declined"})}
      end)

    assert {:error, {:http_status, 422, %{"error" => "declined"}}} =
             ReqHTTP.post(cap, "https://api.stripe.com/v1/charges", %{})
  end

  test "a transport failure resolves to {:error, exception}" do
    cap =
      with_adapter(fn req ->
        {req, %RuntimeError{message: "connection refused"}}
      end)

    assert {:error, %RuntimeError{message: "connection refused"}} =
             ReqHTTP.post(cap, "https://api.stripe.com/v1/charges", %{})
  end

  test "a non-map body is wrapped" do
    cap =
      with_adapter(fn req ->
        {req, Req.Response.new(status: 200, body: "plain text")}
      end)

    assert {:ok, %{"body" => "plain text"}} =
             ReqHTTP.get(cap, "https://api.stripe.com/health")
  end

  test "a disallowed host raises Denied before any request is made" do
    # The adapter would crash the test if reached — it asserts we never get there.
    cap = with_adapter(fn _ -> raise "adapter should not be called" end)

    assert_raise Bloccs.Effects.Denied, ~r/allowlist/, fn ->
      ReqHTTP.post(cap, "https://evil.example.com/", %{})
    end
  end

  test "a disallowed method raises Denied" do
    # POST-only declaration; the GET below is never allowed to leave the VM.
    cap = ReqHTTP.new(%{allow: ["api.stripe.com"], methods: ["POST"]})

    assert_raise Bloccs.Effects.Denied, ~r/method GET/, fn ->
      ReqHTTP.get(cap, "https://api.stripe.com/health")
    end
  end
end
