defmodule Bloccs.SchemaTest do
  use ExUnit.Case, async: false

  alias Bloccs.Schema

  setup do
    Schema.clear!()
    :ok
  end

  describe "register/2 + lookup/1" do
    test "registers and looks up a schema" do
      :ok = Schema.register("ChargeRequest@1", customer_id: :string, amount_cents: :integer)
      assert {:ok, schema} = Schema.lookup("ChargeRequest@1")
      assert schema.name == "ChargeRequest"
      assert schema.version == 1
      assert schema.fields == [customer_id: :string, amount_cents: :integer]
    end

    test "re-registering with same fields is a no-op" do
      :ok = Schema.register("X@1", a: :string)
      :ok = Schema.register("X@1", a: :string)
    end

    test "re-registering with different fields raises" do
      :ok = Schema.register("X@1", a: :string)

      assert_raise ArgumentError, ~r/already registered/, fn ->
        Schema.register("X@1", a: :integer)
      end
    end

    test "lookup returns :error when missing" do
      assert :error = Schema.lookup("Nope@1")
    end
  end

  describe "parse_id!/1" do
    test "parses Name@N" do
      assert {"ChargeRequest", 1} = Schema.parse_id!("ChargeRequest@1")
    end

    test "rejects malformed ids" do
      for bad <- ["", "Foo", "Foo@", "@1", "Foo@0", "Foo@-1", "Foo@1.5", "Foo@abc"] do
        assert_raise ArgumentError, fn -> Schema.parse_id!(bad) end
      end
    end
  end

  describe "validate/2" do
    setup do
      Schema.register("ChargeRequest@1",
        customer_id: :string,
        amount_cents: :integer,
        currency: :string
      )

      :ok
    end

    test "passes when payload matches" do
      assert :ok =
               Schema.validate("ChargeRequest@1", %{
                 customer_id: "cus_1",
                 amount_cents: 2500,
                 currency: "USD"
               })
    end

    test "accepts string keys as well as atom keys" do
      assert :ok =
               Schema.validate("ChargeRequest@1", %{
                 "customer_id" => "cus_1",
                 "amount_cents" => 2500,
                 "currency" => "USD"
               })
    end

    test "reports missing fields" do
      assert {:error, errs} = Schema.validate("ChargeRequest@1", %{customer_id: "cus_1"})
      assert "missing field amount_cents" in errs
      assert "missing field currency" in errs
    end

    test "reports type mismatches" do
      assert {:error, errs} =
               Schema.validate("ChargeRequest@1", %{
                 customer_id: "cus_1",
                 amount_cents: "2500",
                 currency: "USD"
               })

      assert Enum.any?(errs, &(&1 =~ "amount_cents"))
    end
  end

  describe "nested schema refs" do
    setup do
      Schema.register("Address@1", street: :string, city: :string)
      Schema.register("User@1", name: :string, address: "Address@1")
      :ok
    end

    test "validates nested payloads" do
      assert :ok =
               Schema.validate("User@1", %{
                 name: "Alice",
                 address: %{street: "1 Main", city: "Toronto"}
               })
    end

    test "reports nested errors with a dotted path" do
      assert {:error, errs} =
               Schema.validate("User@1", %{
                 name: "Alice",
                 address: %{street: "1 Main"}
               })

      assert Enum.any?(errs, &(&1 =~ "Address@1.missing field city"))
    end
  end

  describe "list schemas" do
    test "lists every registered id" do
      Schema.register("A@1", x: :string)
      Schema.register("B@2", y: :integer)

      assert Enum.sort(Schema.list()) == ["A@1", "B@2"]
    end
  end
end
