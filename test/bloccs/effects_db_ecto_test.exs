defmodule Bloccs.EffectsDBEctoTest do
  @moduledoc """
  The Ecto DB adapter dispatches to a repo's `insert_all/2` at runtime, so it's
  tested with stub repo modules (no real database / no Ecto dependency).
  """

  use ExUnit.Case, async: false

  alias Bloccs.Effects.DB.Ecto, as: EctoDB

  defmodule FakeRepo do
    def insert_all(source, entries, opts) do
      if pid = Application.get_env(:bloccs, :test_repo_pid) do
        send(pid, {:inserted, source, entries, opts})
      end

      # Echo generated columns only when the caller asked for them.
      case Keyword.get(opts, :returning) do
        nil -> {length(entries), nil}
        cols -> {length(entries), Enum.map(entries, fn _ -> Map.new(cols, &{&1, 99}) end)}
      end
    end

    # Reads dispatch to repo.query!/2; echo the SQL + params and return canned
    # rows so the adapter's query-building and row-mapping can be asserted.
    def query!(sql, params) do
      if pid = Application.get_env(:bloccs, :test_repo_pid),
        do: send(pid, {:queried, sql, params})

      %{
        columns: Application.get_env(:bloccs, :test_repo_cols, ["id", "name"]),
        rows: Application.get_env(:bloccs, :test_repo_rows, []),
        num_rows: Application.get_env(:bloccs, :test_repo_num_rows, 1)
      }
    end

    # Minimal transaction semantics: run the body, translate a rollback throw.
    def transaction(fun) do
      {:ok, fun.()}
    catch
      :throw, {:__rollback__, reason} -> {:error, reason}
    end

    def rollback(reason), do: throw({:__rollback__, reason})

    def __adapter__, do: Application.get_env(:bloccs, :test_repo_adapter, Ecto.Adapters.Postgres)
  end

  defmodule FailingRepo do
    def insert_all(_source, _entries, _opts), do: raise("db unavailable")
    def query!(_sql, _params), do: raise("db unavailable")
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  setup do
    on_exit(fn ->
      for k <- [
            EctoDB,
            :test_repo_pid,
            :test_repo_cols,
            :test_repo_rows,
            :test_repo_num_rows,
            :test_repo_adapter
          ] do
        Application.delete_env(:bloccs, k)
      end
    end)

    :ok
  end

  defp cap(repo, opts \\ []) do
    allow = Keyword.get(opts, :allow, ["items:insert"])
    Application.put_env(:bloccs, EctoDB, [repo: repo] ++ Keyword.take(opts, [:returning]))
    EctoDB.new(%{allow: allow})
  end

  test "inserts through the configured repo and returns {:ok, row}" do
    Application.put_env(:bloccs, :test_repo_pid, self())
    cap = cap(FakeRepo)

    assert {:ok, %{name: "c", value: "s"}} =
             EctoDB.insert(cap, :items, name: "c", value: "s")

    # schemaless insert_all gets the table name as a string + a list of one row;
    # with no returning configured, opts carry no :returning
    assert_receive {:inserted, "items", [%{name: "c", value: "s"}], opts}
    refute Keyword.has_key?(opts, :returning)
  end

  test "merges database-generated columns into the row when returning is configured" do
    Application.put_env(:bloccs, :test_repo_pid, self())
    cap = cap(FakeRepo, returning: [:id])

    assert {:ok, %{name: "c", id: 99}} =
             EctoDB.insert(cap, :items, name: "c")

    assert_receive {:inserted, "items", [%{name: "c"}], [returning: [:id]]}
  end

  test "an out-of-scope table raises Denied" do
    cap = cap(FakeRepo)

    assert_raise Bloccs.Effects.Denied, ~r/scope other:insert/, fn ->
      EctoDB.insert(cap, :other, foo: 1)
    end
  end

  test "a missing repo configuration raises a helpful Denied" do
    cap = EctoDB.new(%{allow: ["items:insert"]})

    assert_raise Bloccs.Effects.Denied, ~r/no Ecto repo configured/, fn ->
      EctoDB.insert(cap, :items, foo: 1)
    end
  end

  test "a repo/database error is returned as {:error, exception}" do
    cap = cap(FailingRepo)

    assert {:error, %RuntimeError{message: "db unavailable"}} =
             EctoDB.insert(cap, :items, foo: 1)
  end

  describe "reads" do
    test "all/3 builds a parameterized query and maps rows to string-keyed maps" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      Application.put_env(:bloccs, :test_repo_cols, ["id", "name"])
      Application.put_env(:bloccs, :test_repo_rows, [[1, "ada"], [2, "ada"]])
      cap = cap(FakeRepo, allow: ["items:read"])

      assert {:ok, [%{"id" => 1, "name" => "ada"}, %{"id" => 2, "name" => "ada"}]} =
               EctoDB.all(cap, :items, %{"name" => "ada"})

      assert_receive {:queried, sql, ["ada"]}
      assert sql =~ ~s(SELECT * FROM "items")
      assert sql =~ ~s("name" = $1)
    end

    test "non-Postgres adapters use ? placeholders" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      Application.put_env(:bloccs, :test_repo_adapter, Ecto.Adapters.SQLite3)
      cap = cap(FakeRepo, allow: ["items:read"])

      EctoDB.all(cap, :items, %{"name" => "ada"})

      assert_receive {:queried, sql, ["ada"]}
      assert sql =~ ~s("name" = ?)
      refute sql =~ "$1"
    end

    test "get/3 looks up by id, returning a string-keyed map or nil" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      Application.put_env(:bloccs, :test_repo_cols, ["id", "name"])
      Application.put_env(:bloccs, :test_repo_rows, [[7, "ada"]])
      cap = cap(FakeRepo, allow: ["items:read"])

      assert {:ok, %{"id" => 7, "name" => "ada"}} = EctoDB.get(cap, :items, 7)
      # by-id read filters on the "id" column with a LIMIT 2 (so `one` can flag dups)
      assert_receive {:queried, sql, [7]}
      assert sql =~ ~s("id" = $1)
      assert sql =~ "LIMIT 2"

      Application.put_env(:bloccs, :test_repo_rows, [])
      assert {:ok, nil} = EctoDB.get(cap, :items, 999)
    end

    test "one/3 returns :multiple_results when more than one row matches" do
      Application.put_env(:bloccs, :test_repo_cols, ["id", "name"])
      Application.put_env(:bloccs, :test_repo_rows, [[1, "a"], [2, "a"]])
      cap = cap(FakeRepo, allow: ["items:read"])

      assert {:error, :multiple_results} = EctoDB.one(cap, :items, %{"name" => "a"})
    end

    test "a read without a :read scope raises Denied" do
      cap = cap(FakeRepo, allow: ["items:insert"])

      assert_raise Bloccs.Effects.Denied, ~r/items:read/, fn ->
        EctoDB.all(cap, :items, %{})
      end
    end

    test "a read with no repo configured raises a helpful Denied" do
      cap = EctoDB.new(%{allow: ["items:read"]})

      assert_raise Bloccs.Effects.Denied, ~r/no Ecto repo configured/, fn ->
        EctoDB.all(cap, :items, %{})
      end
    end

    test "a read DB error is returned as {:error, exception}" do
      cap = cap(FailingRepo, allow: ["items:read"])

      assert {:error, %RuntimeError{message: "db unavailable"}} =
               EctoDB.all(cap, :items, %{})
    end
  end

  describe "mutations" do
    test "update/4 sets a literal column" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["items:update"])

      assert {:ok, 1} = EctoDB.update(cap, :items, 5, %{"name" => "x"})

      assert_receive {:queried, sql, ["x", 5]}
      assert sql =~ ~s(UPDATE "items" SET "name" = $1 WHERE "id" = $2)
    end

    test "update/4 builds an atomic increment for {:inc, n}" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["items:update"])

      assert {:ok, 1} = EctoDB.update(cap, :items, 5, %{"votes" => {:inc, 1}})

      assert_receive {:queried, sql, [1, 5]}
      assert sql =~ ~s(SET "votes" = "votes" + $1 WHERE "id" = $2)
    end

    test "delete/3 removes by id" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["items:delete"])

      assert {:ok, 1} = EctoDB.delete(cap, :items, 5)

      assert_receive {:queried, sql, [5]}
      assert sql =~ ~s(DELETE FROM "items" WHERE "id" = $1)
    end

    test "update/4 and delete/3 enforce their scopes" do
      cap = cap(FakeRepo, allow: ["items:read"])

      assert_raise Bloccs.Effects.Denied, ~r/items:update/, fn ->
        EctoDB.update(cap, :items, 1, %{"name" => "x"})
      end

      assert_raise Bloccs.Effects.Denied, ~r/items:delete/, fn ->
        EctoDB.delete(cap, :items, 1)
      end
    end
  end

  describe "transactions" do
    test "transaction/2 (closure) commits and returns the body's {:ok, _}" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["votes:insert", "items:update"])

      assert {:ok, :counted} =
               EctoDB.transaction(cap, fn db ->
                 {:ok, _} = EctoDB.insert(db, :votes, who: "a")
                 {:ok, 1} = EctoDB.update(db, :items, 1, %{"votes" => {:inc, 1}})
                 {:ok, :counted}
               end)

      assert_receive {:inserted, "votes", _, _}
      assert_receive {:queried, sql, [1, 1]}
      assert sql =~ ~s(UPDATE "items")
    end

    test "transaction/2 rolls back (returns {:error, _}) when the body errors" do
      cap = cap(FakeRepo, allow: ["votes:insert"])

      assert {:error, :nope} =
               EctoDB.transaction(cap, fn _db -> {:error, :nope} end)
    end

    test "transaction/2 (declarative ops) runs each op and returns per-op results" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["votes:insert", "items:update"])

      # each op's result is unwrapped: the inserted row, then the update count.
      assert {:ok, [%{who: "a"}, 1]} =
               EctoDB.transaction(cap, [
                 {:insert, :votes, [who: "a"]},
                 {:update, :items, 1, %{"votes" => {:inc, 1}}}
               ])
    end

    test "a transaction with no repo configured raises a helpful Denied" do
      cap = EctoDB.new(%{allow: ["votes:insert"]})

      assert_raise Bloccs.Effects.Denied, ~r/no Ecto repo configured/, fn ->
        EctoDB.transaction(cap, fn _ -> {:ok, :x} end)
      end
    end
  end

  describe "SQL identifier validation" do
    @injected ~s(name" = '' OR 1=1 --)

    test "an injection-shaped filter column is denied before any SQL is built" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["items:read"])

      assert_raise Bloccs.Effects.Denied, ~r/invalid SQL identifier/, fn ->
        EctoDB.all(cap, :items, %{@injected => "x"})
      end

      refute_received {:queried, _, _}
    end

    test "an injection-shaped update column is denied before any SQL is built" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["items:update"])

      assert_raise Bloccs.Effects.Denied, ~r/invalid SQL identifier/, fn ->
        EctoDB.update(cap, :items, 1, %{@injected => "x"})
      end

      refute_received {:queried, _, _}
    end

    test "an injection-shaped insert column is denied before reaching the repo" do
      Application.put_env(:bloccs, :test_repo_pid, self())
      cap = cap(FakeRepo, allow: ["items:insert"])

      assert_raise Bloccs.Effects.Denied, ~r/invalid SQL identifier/, fn ->
        EctoDB.insert(cap, :items, %{@injected => "x"})
      end

      refute_received {:inserted, _, _, _}
    end

    test "ordinary identifiers still pass" do
      cap = cap(FakeRepo, allow: ["items:read"])
      assert {:ok, _} = EctoDB.all(cap, :items, %{"name" => "x", "owner_id" => 7})
    end
  end
end
