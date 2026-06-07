defmodule Bloccs.LineageTest do
  use ExUnit.Case, async: true

  alias Bloccs.Lineage

  describe "new_id/0" do
    test "mints unique, strictly increasing ids" do
      ids = for _ <- 1..100, do: Lineage.new_id()
      assert length(Enum.uniq(ids)) == 100
      assert ids == Enum.sort(ids)
    end
  end

  describe "root/0" do
    test "has no parents and is its own trace" do
      r = Lineage.root()
      assert r.parents == []
      assert r.trace_id == r.msg_id
    end
  end

  describe "of/1 and ensure/1" do
    test "of/1 reads lineage from metadata, nil when absent" do
      l = Lineage.root()
      assert Lineage.of(%{Lineage.key() => l}) == l
      assert Lineage.of(%{}) == nil
      assert Lineage.of(:not_a_map) == nil
    end

    test "ensure/1 injects a root only when absent" do
      assert %{parents: [], trace_id: t, msg_id: t} = Lineage.of(Lineage.ensure(%{}))

      l = Lineage.root()
      assert Lineage.ensure(%{Lineage.key() => l}) == %{Lineage.key() => l}
    end

    test "ensure/1 preserves other metadata keys" do
      meta = Lineage.ensure(%{bloccs_attempt: 2})
      assert meta.bloccs_attempt == 2
      assert %{parents: []} = Lineage.of(meta)
    end
  end

  describe "child/1 (1:1 / split / filter)" do
    test "inherits the parent's trace and lists it as the sole parent" do
      parent = Lineage.root()
      assert Lineage.child(parent) == %{parents: [parent.msg_id], trace_id: parent.trace_id}
    end

    test "an orphan (missing parent) gets no parents and a fresh trace" do
      assert %{parents: [], trace_id: trace} = Lineage.child(nil)
      assert is_integer(trace)
    end
  end

  describe "merge/1 (batch / join fan-in)" do
    test "lists every parent and starts a fresh trace" do
      a = Lineage.root()
      b = Lineage.root()
      ctx = Lineage.merge([a, b])

      assert ctx.parents == [a.msg_id, b.msg_id]
      # a new logical message: not either input's trace
      assert ctx.trace_id != a.trace_id
      assert ctx.trace_id != b.trace_id
    end

    test "ignores nil / lineage-less inputs" do
      a = Lineage.root()
      assert %{parents: parents} = Lineage.merge([a, nil])
      assert parents == [a.msg_id]
    end
  end

  describe "stamp/1" do
    test "mints a fresh msg_id and keeps the context's parents + trace" do
      ctx = %{parents: [7, 9], trace_id: 3}
      l = Lineage.stamp(ctx)

      assert l.parents == [7, 9]
      assert l.trace_id == 3
      assert is_integer(l.msg_id) and l.msg_id not in [7, 9, 3]
    end

    test "each stamp of the same context is a distinct message" do
      ctx = Lineage.child(Lineage.root())
      assert Lineage.stamp(ctx).msg_id != Lineage.stamp(ctx).msg_id
    end
  end
end
