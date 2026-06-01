defmodule Bloccs.Test.WiredNode do
  @moduledoc """
  Fixture for `Bloccs.NodeMacroWiredFieldsTest`.

  Its manifest declares every runtime field that was parsed-but-unwired in
  v0.1 and is wired as of v0.2 (retry, timeout_ms, idempotency,
  ports.in.buffer, [observability]). Compiling this module via
  `Code.compile_file/1` must NOT emit a "parsed-but-unwired" warning. Never
  `use`d outside the dedicated test.
  """

  use Bloccs.Node, manifest: "manifest.bloccs"

  def transform(payload, _ctx), do: {:ok, payload}
  def execute(payload, _ctx), do: {:emit, :out_a, payload}
end
