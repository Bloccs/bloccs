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
  - On success returns `{:ok, attrs_as_map}`. v0.3 does not echo
    database-generated columns (a schemaless `insert_all` would need an explicit
    `returning` column list); include any id you need in `attrs`, or read it
    back yourself. Richer returning is future work.
  - A repo/database error is caught and returned as `{:error, exception}`.

  For a fully custom datastore, implement the `Bloccs.Effects.DB` behaviour
  directly instead of using this adapter.
  """

  @behaviour Bloccs.Effects.DB

  alias Bloccs.Effects

  defstruct allow: [], repo: nil

  @type t :: %__MODULE__{allow: [String.t()], repo: module() | nil}

  @impl true
  def new(%{allow: allow}), do: %__MODULE__{allow: allow, repo: configured_repo()}

  @impl true
  def insert(%__MODULE__{allow: allow, repo: repo}, table, attrs) do
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
        do_insert(repo, table, Map.new(attrs))
    end
  end

  defp do_insert(repo, table, row) do
    {_count, _returned} = repo.insert_all(to_string(table), [row])
    {:ok, row}
  rescue
    e -> {:error, e}
  end

  defp configured_repo do
    :bloccs
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:repo)
  end
end
