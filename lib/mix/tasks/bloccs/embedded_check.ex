defmodule Mix.Tasks.Bloccs.EmbeddedCheck do
  @moduledoc false
  # Shared by `mix bloccs.validate` and `mix bloccs.compile`: compile the project
  # so node modules are loadable, then compare each manifest with the one its
  # module was compiled with (`Bloccs.Compiler.check_embedded_manifests/1`).
  #
  # `--no-compile` skips both steps, for validating a manifest before its module
  # exists or while the project does not compile.

  alias Bloccs.Compiler
  alias Bloccs.Manifest.{Network, Node}

  @doc "Compile the project unless `--no-compile` was given."
  @spec prepare(keyword()) :: :ok
  def prepare(opts) do
    if enabled?(opts), do: Mix.Task.run("compile")
    :ok
  end

  @doc "Compare a validated manifest with its compiled module(s). A no-op under `--no-compile`."
  @spec check(Network.t() | Node.t(), keyword()) :: :ok | {:error, [Bloccs.Validator.Issue.t()]}
  def check(manifest, opts) do
    cond do
      not enabled?(opts) -> :ok
      match?(%Network{}, manifest) -> Compiler.check_embedded_manifests(manifest)
      true -> Compiler.check_embedded_manifest(manifest)
    end
  end

  @doc "Say so when the comparison was skipped, so a pass is not read as covering it."
  @spec note_skipped(keyword()) :: :ok
  def note_skipped(opts) do
    if not enabled?(opts) do
      Mix.shell().info([
        :yellow,
        "  ⚠ --no-compile: not compared with the compiled node modules",
        :reset
      ])
    end

    :ok
  end

  defp enabled?(opts), do: Keyword.get(opts, :compile, true)
end
