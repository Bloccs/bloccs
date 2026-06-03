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
  end

  defmodule FailingRepo do
    def insert_all(_source, _entries, _opts), do: raise("db unavailable")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:bloccs, EctoDB)
      Application.delete_env(:bloccs, :test_repo_pid)
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
end
