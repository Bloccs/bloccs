defmodule Bloccs.Test.UnwiredNode do
  @moduledoc """
  Fixture for `Bloccs.NodeMacroUnwiredFieldsTest`.

  Its manifest declares every v0.1-parsed-but-unwired field (retry,
  timeout_ms, idempotency, ports.in.buffer, [observability]). Compiling
  this module via `Code.compile_file/1` should emit one `IO.warn` summary
  listing each unwired field. Never `use`d outside the dedicated test.
  """

  use Bloccs.Node, manifest: "manifest.bloccs"

  def transform(payload, _ctx), do: {:ok, payload}
  def execute(payload, _ctx), do: {:emit, :out_a, payload}
end
