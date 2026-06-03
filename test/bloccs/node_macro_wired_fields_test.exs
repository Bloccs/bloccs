defmodule Bloccs.NodeMacroWiredFieldsTest do
  @moduledoc """
  Regression guard for v0.2: the runtime fields that were parsed-but-unwired
  in v0.1 (retry, timeout_ms, idempotency, ports.in.buffer, [observability])
  are now wired, so a node declaring them must produce NO "parsed-but-unwired"
  warning — neither from `Validator.warnings/1` nor from the `Bloccs.Node`
  macro's `IO.warn`. (As of subgraph composition, `[expose]` is wired too, so
  `Validator.warnings/1` returns `[]` across the board.)
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bloccs.{Parser, Validator}

  @fixture_path Path.expand("../fixtures/wired_node/impl.ex", __DIR__)
  @manifest_path Path.expand("../fixtures/wired_node/manifest.bloccs", __DIR__)

  test "Validator.warnings/1 returns [] for a node declaring the now-wired fields" do
    assert {:ok, manifest} = Parser.parse_node(@manifest_path)
    assert [] = Validator.warnings(manifest)
  end

  test "Bloccs.Node macro compiles such a node without a parsed-but-unwired warning" do
    captured = capture_io(:stderr, fn -> Code.compile_file(@fixture_path) end)

    refute captured =~ "not yet wired"
    refute captured =~ "parsed but"
  end
end
