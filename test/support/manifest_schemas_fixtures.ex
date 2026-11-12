defmodule Bloccs.Integration.ManifestSchemasFixtures do
  @moduledoc """
  Node impls for schemas declared in manifests. `source.bloccs` declares the
  schemas; `sink.bloccs` declares none and names one on its in-port. Nothing
  here is put in the `Bloccs.Schema` registry.
  """

  defmodule Source do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/manifest_schemas/source.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :out, data}
  end

  defmodule Sink do
    @moduledoc false
    use Bloccs.Node, manifest: "../fixtures/manifest_schemas/sink.bloccs"
    def transform(data, _ctx), do: {:ok, data}
    def execute(data, _ctx), do: {:emit, :done, data}
  end
end
