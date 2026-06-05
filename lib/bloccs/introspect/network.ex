defmodule Bloccs.Introspect.Network do
  @moduledoc """
  A normalized, runtime view of a running network — the single shape an
  observability tool reads. Assembled by `Bloccs.Introspect.network/1` from the
  generated supervisor and each node's compiled manifest.
  """

  @type endpoint :: {atom(), atom()}

  @type port_view :: %{name: atom(), schema: String.t(), buffer: pos_integer() | nil}

  @typedoc "A node's notation glyph (see `Bloccs.Introspect.glyph/1`)."
  @type glyph ::
          :node | :node_effect | :source | :sink | :split | :batch | :join | :throttle | :delay

  @typedoc "A node's drawable identity: kind + the canonical notation glyph."
  @type node_view :: %{
          id: atom(),
          kind: :source | :transform | :router | :sink,
          glyph: glyph(),
          ports_in: [port_view()],
          ports_out: [port_view()],
          effects: [:http | :db | :time | :random],
          concurrency: pos_integer(),
          doc: %{intent: String.t() | nil, owner: String.t() | nil}
        }

  @type edge_view :: %{from: endpoint(), to: endpoint()}

  @type summary :: %{
          id: atom(),
          version: String.t(),
          node_count: non_neg_integer(),
          edge_count: non_neg_integer(),
          started_at: integer(),
          supervisor: module()
        }

  @type t :: %__MODULE__{
          id: atom(),
          version: String.t(),
          supervisor: module(),
          started_at: integer() | nil,
          nodes: [node_view()],
          edges: [edge_view()],
          expose: %{in: map(), out: map()},
          supervision: %{
            strategy: atom(),
            max_restarts: non_neg_integer(),
            max_seconds: pos_integer()
          }
        }

  @enforce_keys [:id, :version, :supervisor]
  defstruct id: nil,
            version: nil,
            supervisor: nil,
            started_at: nil,
            nodes: [],
            edges: [],
            expose: %{in: %{}, out: %{}},
            supervision: %{}
end
