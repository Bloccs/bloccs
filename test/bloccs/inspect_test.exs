defmodule Bloccs.InspectTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:bloccs, :inspect) end)
    :ok
  end

  defp enable(opts \\ []) do
    Application.put_env(:bloccs, :inspect, Keyword.merge([enabled: true], opts))
  end

  describe "capture/1" do
    test "returns nil when disabled (the default)" do
      assert Bloccs.Inspect.capture(%{id: 1}) == nil
      refute Bloccs.Inspect.enabled?()
    end

    test "renders a string snapshot when enabled" do
      enable()
      snap = Bloccs.Inspect.capture(%{id: 7, type: "retail"})
      assert is_binary(snap)
      assert snap =~ "id: 7"
      assert snap =~ "retail"
    end

    test "redacts matching keys at any depth, atom or string form" do
      enable(redact: [:password, :token])

      snap =
        Bloccs.Inspect.capture(%{
          "token" => "abc",
          password: "hunter2",
          nested: %{token: "xyz"},
          id: 1
        })

      assert snap =~ "[redacted]"
      refute snap =~ "hunter2"
      refute snap =~ "abc"
      refute snap =~ "xyz"
      assert snap =~ ":id => 1"
    end

    test "truncates to max_bytes" do
      enable(max_bytes: 20)
      snap = Bloccs.Inspect.capture(%{blob: String.duplicate("x", 500)})
      assert String.length(snap) <= 21
      assert String.ends_with?(snap, "…")
    end

    test "leaves structs as their type while redacting fields" do
      enable(redact: [:secret])
      snap = Bloccs.Inspect.capture(%URI{host: "example.com", userinfo: "u"})
      assert snap =~ "URI"
      assert snap =~ "example.com"
    end
  end

  describe "[:bloccs, :emit] telemetry" do
    test "carries a redacted payload snapshot when enabled" do
      enable(redact: [:password])
      parent = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:bloccs, :emit],
        fn _event, _measure, meta, _cfg -> send(parent, {:emit, meta}) end,
        nil
      )

      # A registered network with no edges: dispatch reaches nothing but
      # still emits the event.
      :ok = Bloccs.Router.register(:inspect_test_net, [])
      on_exit(fn -> Bloccs.Router.unregister(:inspect_test_net) end)
      Bloccs.Router.dispatch(:inspect_test_net, :a, :out, %{password: "hunter2", id: 7})

      assert_receive {:emit, meta}
      assert is_binary(meta.payload)
      assert meta.payload =~ "[redacted]"
      refute meta.payload =~ "hunter2"
      assert meta.payload =~ "id: 7"

      :telemetry.detach(handler)
    end

    test "payload is nil when capture is disabled" do
      parent = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:bloccs, :emit],
        fn _event, _measure, meta, _cfg -> send(parent, {:emit, meta}) end,
        nil
      )

      :ok = Bloccs.Router.register(:inspect_test_net, [])
      on_exit(fn -> Bloccs.Router.unregister(:inspect_test_net) end)
      Bloccs.Router.dispatch(:inspect_test_net, :a, :out, %{id: 1})

      assert_receive {:emit, meta}
      assert meta.payload == nil

      :telemetry.detach(handler)
    end
  end
end
