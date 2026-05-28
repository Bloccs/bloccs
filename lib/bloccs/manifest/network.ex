defmodule Bloccs.Manifest.NetworkNode do
  @moduledoc """
  An instantiated node within a network.

  `local_id` is the symbol used in the network file (e.g. `:charge`); `use_path`
  points at the underlying node manifest; `manifest` is the loaded node manifest
  itself; `config` is the per-instance config overlay (used by parameterized
  nodes like `email_send` with different `template` values).
  """

  @type t :: %__MODULE__{
          local_id: atom(),
          use_path: Path.t(),
          manifest: Bloccs.Manifest.Node.t(),
          config: map()
        }

  @enforce_keys [:local_id, :use_path, :manifest]
  defstruct [:local_id, :use_path, :manifest, config: %{}]
end

defmodule Bloccs.Manifest.Edge do
  @moduledoc """
  A wire connecting an output port on one node to one or more input ports.
  """

  @type endpoint :: {atom(), atom()}

  @type t :: %__MODULE__{
          from: endpoint(),
          to: [endpoint()]
        }

  @enforce_keys [:from, :to]
  defstruct [:from, :to]
end

defmodule Bloccs.Manifest.Expose do
  @moduledoc """
  Network-level port exposure — promotes a network to be useable as a
  subgraph node. v0.1 does not consume `expose` (subgraph composition is
  v0.2) but the parser still captures it so manifests are forward-compatible.
  """

  @type t :: %__MODULE__{
          in: %{atom() => {atom(), atom()}},
          out: %{atom() => {atom(), atom()}}
        }

  defstruct in: %{}, out: %{}
end

defmodule Bloccs.Manifest.Supervision do
  @moduledoc """
  Supervision strategy declared at the network level.
  """

  @type strategy :: :one_for_one | :one_for_all | :rest_for_one

  @type t :: %__MODULE__{
          strategy: strategy(),
          max_restarts: non_neg_integer(),
          max_seconds: pos_integer()
        }

  defstruct strategy: :one_for_one, max_restarts: 3, max_seconds: 5

  @valid ~w(one_for_one one_for_all rest_for_one)a

  @spec cast_strategy!(String.t()) :: strategy()
  def cast_strategy!(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @valid, do: atom, else: raise(ArgumentError, "unknown strategy #{value}")
  rescue
    ArgumentError ->
      reraise(ArgumentError, "unknown supervision strategy #{inspect(value)}", __STACKTRACE__)
  end

  def valid_strategies, do: @valid
end

defmodule Bloccs.Manifest.Network do
  @moduledoc """
  A parsed network manifest. Declares topology: which nodes participate,
  how their ports are wired, supervision strategy, deploy concurrency.
  """

  alias Bloccs.Manifest.{NetworkNode, Edge, Expose, Supervision}

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          id: String.t(),
          version: String.t(),
          runtime: String.t(),
          nodes: %{atom() => NetworkNode.t()},
          edges: [Edge.t()],
          expose: Expose.t(),
          supervision: Supervision.t(),
          deploy: %{concurrency: %{atom() => pos_integer()}, placement: String.t() | nil}
        }

  @enforce_keys [:id, :version, :nodes, :edges]
  defstruct [
    :path,
    :id,
    :version,
    runtime: "beam",
    nodes: %{},
    edges: [],
    expose: %Expose{},
    supervision: %Supervision{},
    deploy: %{concurrency: %{}, placement: nil}
  ]
end
