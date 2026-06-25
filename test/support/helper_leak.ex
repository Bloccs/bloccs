defmodule Bloccs.Test.HelperLeak.Clean do
  @moduledoc false
  # A pure same-app helper reachable from pure_core — must NOT be flagged.
  def normalize(payload) when is_map(payload), do: Map.put(payload, :seen, true)
end

defmodule Bloccs.Test.HelperLeak.Writer do
  @moduledoc false
  # A same-app helper that reaches the world. The node body calls this and so
  # passes the intraprocedural check (a same-app call is permitted); only the
  # transitive pass, following into this body, sees the File.write!.
  def persist(payload) do
    File.write!("/tmp/bloccs-helper-leak", :erlang.term_to_binary(payload))
    payload
  end
end

defmodule Bloccs.Test.HelperLeak.Node do
  @moduledoc false
  # Fixture for `Bloccs.Lint.TransitiveTest`. Its own body is clean (only same-app
  # helper calls + an emit), so it compiles; the leak lives one hop away in
  # `Writer.persist/1`. Never wired into a running network.

  use Bloccs.Node, manifest: "helper_leak.bloccs"

  alias Bloccs.Test.HelperLeak.{Clean, Writer}

  def transform(payload, _ctx), do: {:ok, Clean.normalize(payload)}

  def execute(payload, _ctx) do
    _ = Writer.persist(payload)
    {:emit, :out, payload}
  end
end
