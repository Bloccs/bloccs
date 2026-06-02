defmodule Bloccs.Effects.DB.Ecto do
  @moduledoc """
  Real DB backend that writes through an Ecto repo — with **no compile-time
  dependency on Ecto**. It performs a schemaless `repo.insert_all(table, [row])`
  via a runtime call on the repo module you configure, so the published `bloccs`
  package never forces `ecto`/`postgrex` on consumers who don't use the DB axis.

  ## Setup

  Add `ecto_sql` + your driver (e.g. `postgrex`) to *your* app, define a repo,
  then point bloccs at it:

      config :bloccs, :effect_backends, db: Bloccs.Effects.DB.Ecto
      config :bloccs, Bloccs.Effects.DB.Ecto, repo: MyApp.Repo

  Nodes keep calling `Bloccs.Effects.DB.insert(ctx.effects.db, table, attrs)` —
  no node changes when you switch from the mock.

  ## Semantics

  - The declared `"table:insert"` scope is enforced; a violation raises
    `Bloccs.Effects.Denied` (like the mock).
  - On success returns `{:ok, row}`. If you configure `returning` columns
    (below), database-generated values (e.g. an auto-increment `id`) are merged
    into the returned row; otherwise the row is just the attrs you inserted.
  - A repo/database error is caught and returned as `{:error, exception}`.

  ## Returning generated columns

  A schemaless `insert_all` needs an explicit column list to echo generated
  values. Configure one list, applied to every insert (set it to your primary
  key — tables lacking those columns will error):

      config :bloccs, Bloccs.Effects.DB.Ecto, repo: MyApp.Repo, returning: [:id]

  For a fully custom datastore, implement the `Bloccs.Effects.DB` behaviour
  directly instead of using this adapter.
  """

  @behaviour Bloccs.Effects.DB

  alias Bloccs.Effects

  defstruct allow: [], repo: nil, returning: nil

  @type t :: %__MODULE__{
          allow: [String.t()],
          repo: module() | nil,
          returning: [atom()] | nil
        }

  @impl true
  def new(%{allow: allow}) do
    cfg = Application.get_env(:bloccs, __MODULE__, [])
    %__MODULE__{allow: allow, repo: cfg[:repo], returning: cfg[:returning]}
  end

  @impl true
  def insert(%__MODULE__{allow: allow, repo: repo, returning: returning}, table, attrs) do
    scope = "#{table}:insert"

    cond do
      scope not in allow ->
        Effects.deny!(:db, "scope #{scope} not in #{inspect(allow)}")

      is_nil(repo) ->
        Effects.deny!(
          :db,
          "no Ecto repo configured for #{inspect(__MODULE__)}; " <>
            "set config :bloccs, #{inspect(__MODULE__)}, repo: MyApp.Repo"
        )

      true ->
        do_insert(repo, table, Map.new(attrs), returning)
    end
  end

  defp do_insert(repo, table, row, returning) do
    opts = if returning, do: [returning: returning], else: []

    case repo.insert_all(to_string(table), [row], opts) do
      {_count, [generated]} when is_map(generated) -> {:ok, Map.merge(row, generated)}
      {_count, _none} -> {:ok, row}
    end
  rescue
    e -> {:error, e}
  end
end
