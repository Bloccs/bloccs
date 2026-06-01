defmodule Bloccs.EffectsDBEctoTest do
  @moduledoc """
  The Ecto DB adapter dispatches to a repo's `insert_all/2` at runtime, so it's
  tested with stub repo modules (no real database / no Ecto dependency).
  """

  use ExUnit.Case, async: false

  alias Bloccs.Effects.DB.Ecto, as: EctoDB

  defmodule FakeRepo do
    def insert_all(source, entries) do
      if pid = Application.get_env(:bloccs, :test_repo_pid) do
        send(pid, {:inserted, source, entries})
      end

      {length(entries), nil}
    end
  end

  defmodule FailingRepo do
    def insert_all(_source, _entries), do: raise("db unavailable")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:bloccs, EctoDB)
      Application.delete_env(:bloccs, :test_repo_pid)
    end)

    :ok
  end

  defp cap(repo, allow \\ ["charges:insert"]) do
    Application.put_env(:bloccs, EctoDB, repo: repo)
    EctoDB.new(%{allow: allow})
  end

  test "inserts through the configured repo and returns {:ok, row}" do
    Application.put_env(:bloccs, :test_repo_pid, self())
    cap = cap(FakeRepo)

    assert {:ok, %{customer_id: "c", stripe_id: "s"}} =
             EctoDB.insert(cap, :charges, customer_id: "c", stripe_id: "s")

    # schemaless insert_all gets the table name as a string + a list of one row
    assert_receive {:inserted, "charges", [%{customer_id: "c", stripe_id: "s"}]}
  end

  test "an out-of-scope table raises Denied" do
    cap = cap(FakeRepo)

    assert_raise Bloccs.Effects.Denied, ~r/scope other:insert/, fn ->
      EctoDB.insert(cap, :other, foo: 1)
    end
  end

  test "a missing repo configuration raises a helpful Denied" do
    cap = EctoDB.new(%{allow: ["charges:insert"]})

    assert_raise Bloccs.Effects.Denied, ~r/no Ecto repo configured/, fn ->
      EctoDB.insert(cap, :charges, foo: 1)
    end
  end

  test "a repo/database error is returned as {:error, exception}" do
    cap = cap(FailingRepo)

    assert {:error, %RuntimeError{message: "db unavailable"}} =
             EctoDB.insert(cap, :charges, foo: 1)
  end
end
