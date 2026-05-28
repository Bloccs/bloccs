defmodule Bloccs.Test.NodeFixtures do
  @moduledoc """
  Fixture manifests embedded directly in lib/test for the Bloccs.Node macro
  tests. Files live next to this support module so the manifest paths resolve
  cleanly when the macro evaluates `Path.expand/2` against the caller file.
  """

  def write_node!(dir, filename, contents) do
    path = Path.join(dir, filename)
    File.write!(path, contents)
    path
  end
end
