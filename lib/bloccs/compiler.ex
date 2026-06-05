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

  alias Bloccs.Manifest.Network
  alias Bloccs.Compiler

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
  """
  @spec compile_and_load(Network.t(), keyword()) ::
          {:ok, module()}
  def compile_and_load(%Network{} = network, opts \\ []) do
    {:ok, %{supervisor: sup, files: files}} = compile(network, opts)

    Enum.each(files, &Code.require_file/1)
    {:ok, sup}
  end

  defp default_dest_dir(%Network{id: id}) do
    base = Mix.Project.build_path()
    Path.join([base, "bloccs_generated", id])
  end
end
