defmodule Bloccs.Compiler do
  @moduledoc """
  Compiles a parsed network manifest into Broadway-based source files written
  to `_build/<MIX_ENV>/bloccs_generated/<network>/`.

  Two stages:

  - `Bloccs.Compiler.Node` — one Broadway pipeline module per node
  - `Bloccs.Compiler.Network` — a Supervisor module that boots every pipeline
    and an edges-table module the Router consumes

  Then the caller `Code.require_file/1`s the emitted files (or
  `Mix.Task` does it as part of `bloccs.compile`) and starts the supervisor.
  """

  alias Bloccs.Manifest.{Network, NetworkNode}
  alias Bloccs.Compiler
  alias Bloccs.Validator.Issue

  @doc """
  Compile a network. Writes source files to `dest_dir` (defaults to
  `_build/<MIX_ENV>/bloccs_generated/<network_id>`).

  Returns `{:ok, %{supervisor: module, files: [path]}}`.
  """
  @spec compile(Network.t(), keyword()) ::
          {:ok, %{supervisor: module(), files: [Path.t()]}}
  def compile(%Network{} = network, opts \\ []) do
    dest_dir =
      Keyword.get_lazy(opts, :dest_dir, fn -> default_dest_dir(network) end)

    File.mkdir_p!(Path.join(dest_dir, "nodes"))

    node_files =
      Enum.flat_map(network.nodes, fn {_local_id, nn} ->
        Compiler.Node.compile(nn, network, dest_dir)
      end)

    sup_file = Compiler.Network.compile(network, dest_dir)

    {:ok,
     %{
       supervisor: Compiler.Network.supervisor_module(network),
       files: node_files ++ [sup_file]
     }}
  end

  @doc """
  Convenience: compile the network and immediately `Code.require_file/1`
  every emitted source so the modules become callable.

  Returns `{:error, issues}` without loading anything when a node's manifest
  differs from the one its module was compiled with (see
  `check_embedded_manifests/1`).
  """
  @spec compile_and_load(Network.t(), keyword()) ::
          {:ok, module()} | {:error, [Issue.t()]}
  def compile_and_load(%Network{} = network, opts \\ []) do
    with :ok <- check_embedded_manifests(network) do
      {:ok, %{supervisor: sup, files: files}} = compile(network, opts)

      Enum.each(files, &Code.require_file/1)
      {:ok, sup}
    end
  end

  @doc """
  Check that every node the network references is the manifest its module was
  compiled with.

  A node module embeds its manifest at compile time (`use Bloccs.Node, manifest:
  ...`), and the runtime reads port schemas, effects, timeout, retry and
  idempotency from that embedded copy. If the network references a *different*
  manifest whose contract points at the same module, the validator checks one
  manifest while the node runs another: for example a manifest that declares no
  effects in front of a module that was granted HTTP. This rejects that.

  Modules that are not loadable, or that do not `use Bloccs.Node`, are skipped:
  this check only compares two manifests when both exist.
  """
  @spec check_embedded_manifests(Network.t()) :: :ok | {:error, [Issue.t()]}
  def check_embedded_manifests(%Network{nodes: nodes, path: path}) do
    issues =
      nodes
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {local_id, %NetworkNode{manifest: manifest}} ->
        module = manifest.contract.pure_core.module

        with {:module, _} <- Code.ensure_loaded(module),
             true <- function_exported?(module, :__bloccs_manifest__, 0),
             embedded = module.__bloccs_manifest__(),
             false <- same_manifest?(manifest, embedded) do
          [
            %Issue{
              file: path,
              scope: "[nodes].#{local_id}",
              message:
                "manifest #{manifest.path} differs from the embedded manifest of " <>
                  "#{inspect(module)} (compiled from #{embedded.path}); the node would run " <>
                  "with the embedded one. Differing sections: " <>
                  Enum.join(differing_keys(manifest, embedded), ", ")
            }
          ]
        else
          _ -> []
        end
      end)

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp same_manifest?(a, b), do: differing_keys(a, b) == []

  # `:path` is where the file was read from, not part of what the node declares.
  defp differing_keys(a, b) do
    for key <- Map.keys(a) -- [:__struct__, :path],
        Map.get(a, key) != Map.get(b, key),
        do: Atom.to_string(key)
  end

  defp default_dest_dir(%Network{id: id}) do
    base = Mix.Project.build_path()
    Path.join([base, "bloccs_generated", id])
  end
end
