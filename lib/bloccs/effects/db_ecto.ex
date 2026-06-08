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

  - The declared `"table:insert"` / `"table:read"` scope is enforced; a violation
    raises `Bloccs.Effects.Denied` (like the mock).
  - On success `insert/3` returns `{:ok, row}`. If you configure `returning`
    columns (below), database-generated values (e.g. an auto-increment `id`) are
    merged into the returned row; otherwise the row is just the attrs you inserted.
  - A repo/database error is caught and returned as `{:error, exception}`.

  ## Reads

  `get/3` / `all/3` / `one/3` run a parameterized `repo.query!/2` (the only path
  that needs no compile-time `Ecto.Query` macro) and return rows as **string-keyed
  maps**. The filter is ANDed equality only (`%{column => value}`). Placeholders
  are chosen from `repo.__adapter__/0` — `$1, $2, …` for
  `Ecto.Adapters.Postgres`, `?` otherwise (SQLite3 / MyXQL). Identifiers are
  double-quoted, so **Postgres and SQLite3 are supported**; back-tick dialects
  (MySQL) are not in this version — implement the `Bloccs.Effects.DB` behaviour
  directly for those.

  > Table and filter-column names are interpolated into SQL (values are always
  > parameterized). They come from node source — trusted code, like the table
  > name in `insert/3` — not from message payloads. Don't derive them from
  > untrusted input.

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

  @impl true
  def get(%__MODULE__{} = cap, table, id), do: one(cap, table, %{"id" => id})

  @impl true
  def all(%__MODULE__{} = cap, table, filter), do: read(cap, table, filter, :all)

  @impl true
  def one(%__MODULE__{} = cap, table, filter) do
    case read(cap, table, filter, :one) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:ok, _many} -> {:error, :multiple_results}
      {:error, _} = err -> err
    end
  end

  defp read(%__MODULE__{allow: allow, repo: repo}, table, filter, mode) do
    scope = "#{table}:read"

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
        do_read(repo, table, filter, mode)
    end
  end

  defp do_read(repo, table, filter, mode) do
    {where, params} = build_where(repo, filter)
    # `:one` fetches up to two rows so the facade can flag a multi-row match.
    limit = if mode == :one, do: " LIMIT 2", else: ""
    sql = ~s(SELECT * FROM "#{table}"#{where}#{limit})

    %{columns: cols, rows: rows} = repo.query!(sql, params)
    {:ok, Enum.map(rows, fn row -> Map.new(Enum.zip(cols, row)) end)}
  rescue
    e -> {:error, e}
  end

  defp build_where(_repo, filter) when map_size(filter) == 0, do: {"", []}

  defp build_where(repo, filter) do
    entries = Enum.to_list(filter)

    clauses =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {{col, _v}, i} -> ~s("#{col}" = #{placeholder(repo, i)}) end)

    {" WHERE " <> Enum.join(clauses, " AND "), Enum.map(entries, &elem(&1, 1))}
  end

  defp placeholder(repo, i) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> "$#{i}"
      _ -> "?"
    end
  end
end
