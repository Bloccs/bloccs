defmodule Bloccs.Lineage do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > Infrastructure called by compiler-generated pipelines — not part of the
  > stable user API. You drive this through manifests, not by calling it directly;
  > signatures may change between minor versions.

  Per-message causal lineage — the identity that lets a single logical message be
  tracked across the hops it takes through a network.

  Each message carries a small lineage map in its `Broadway.Message` metadata
  (under `key/0`), **never in the payload** — payloads have a declared `Name@N`
  schema we must not pollute:

      %{msg_id: id, parents: [id], trace_id: id}

  - `msg_id` — a unique id for *this* message instance, minted at each emit.
  - `parents` — the `msg_id`s of the input message(s) that caused this emit. One
    parent for a transform/split, *many* for a fan-in (batch, join).
  - `trace_id` — a root-correlation convenience: the ingress `msg_id`, propagated
    unchanged on 1:1 and fan-out, and **minted fresh** on fan-in (a merge is a
    new logical message; `parents` preserves the cross-trace links).

  The primitive is `msg_id` + `parents` — a causal DAG. `trace_id` is a derived
  convenience for the common 1:1 chain and for cheap grouping.

  Ids are `System.unique_integer([:positive, :monotonic])` — cheap on the hot
  path and monotonic within a runtime (single-node assumption for v1).
  """

  @key :bloccs_lineage

  @type id :: pos_integer()
  @type t :: %{msg_id: id(), parents: [id()], trace_id: id()}
  @type ctx :: %{parents: [id()], trace_id: id()}

  @doc "The `Broadway.Message` metadata key lineage is carried under."
  @spec key() :: :bloccs_lineage
  def key, do: @key

  @doc "Mint a fresh, unique, monotonic id."
  @spec new_id() :: id()
  def new_id, do: System.unique_integer([:positive, :monotonic])

  @doc "A root lineage for a message with no upstream (external ingress)."
  @spec root() :: %{msg_id: id(), parents: [], trace_id: id()}
  def root do
    id = new_id()
    %{msg_id: id, parents: [], trace_id: id}
  end

  @doc "Extract the lineage carried in a message's metadata, or `nil` if absent."
  @spec of(map() | term()) :: t() | nil
  def of(meta) when is_map(meta), do: Map.get(meta, @key)
  def of(_), do: nil

  @doc """
  Ensure a metadata map carries a lineage — inject a `root/0` if it has none.
  Called when a producer builds a message, so external ingress (a bare `push`
  with no lineage) becomes a tracked root while internal hops keep theirs.
  """
  @spec ensure(map()) :: map()
  def ensure(meta) when is_map(meta) do
    if Map.has_key?(meta, @key), do: meta, else: Map.put(meta, @key, root())
  end

  @doc """
  Lineage context for a 1:1 / split / filter emit from a single parent: the child
  inherits the parent's `trace_id` and lists it as its sole parent. A `nil` parent
  (an orphan emit, e.g. a direct `Router.dispatch/4`) starts a fresh trace with no
  parents.
  """
  @spec child(t() | nil) :: ctx()
  def child(%{msg_id: pid, trace_id: trace}), do: %{parents: [pid], trace_id: trace}
  def child(_), do: %{parents: [], trace_id: new_id()}

  @doc """
  Lineage context for a fan-in (batch / join) emit from many parents: a fresh
  `trace_id` (the merge is a new logical message), with every input listed as a
  parent. `nil` / lineage-less inputs are ignored.
  """
  @spec merge([t() | nil]) :: ctx()
  def merge(parents) when is_list(parents) do
    ids = parents |> Enum.map(&parent_id/1) |> Enum.reject(&is_nil/1)
    %{parents: ids, trace_id: new_id()}
  end

  @doc "Mint a full lineage for an emitted message from a context, generating its `msg_id`."
  @spec stamp(ctx()) :: t()
  def stamp(%{parents: parents, trace_id: trace}),
    do: %{msg_id: new_id(), parents: parents, trace_id: trace}

  defp parent_id(%{msg_id: id}), do: id
  defp parent_id(_), do: nil
end
