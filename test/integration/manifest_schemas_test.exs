defmodule Bloccs.Integration.ManifestSchemasTest do
  use ExUnit.Case, async: false

  alias Bloccs.{Compiler, Parser, Producer, Router, Schema, Validator}
  alias Bloccs.Manifest.Schemas

  @fixtures "test/fixtures/manifest_schemas"

  defp parse!(name) do
    {:ok, network} = Parser.parse_network(Path.join(@fixtures, name))
    network
  end

  defp messages(issues), do: Enum.map(issues, &"#{&1.scope} #{&1.message}")

  describe "parsing" do
    test "a node manifest's [schemas] is cast to typed fields" do
      {:ok, node} = Parser.parse_node(Path.join(@fixtures, "source.bloccs"))

      assert node.schemas == %{
               "MsRaw@1" => [],
               "MsCustomer@1" => [name: :string],
               "MsOrder@1" => [
                 buyer: "MsCustomer@1",
                 id: :string,
                 tags: {:list, :string},
                 total: :integer
               ]
             }
    end

    test "an unknown field type and a malformed id are parse errors" do
      assert {:error, ["MsA@1.n: unknown type \"number\""]} =
               Schemas.cast(%{"MsA@1" => %{"n" => "number"}})

      assert {:error, ["schema id \"order\" must match Name@N"]} =
               Schemas.cast(%{"order" => %{"id" => "string"}})

      assert {:error, ["MsA@1.xs: unknown type [\"string\", \"integer\"]"]} =
               Schemas.cast(%{"MsA@1" => %{"xs" => ["string", "integer"]}})
    end

    test "a bad [schemas] table fails the manifest with its section" do
      toml =
        File.read!(Path.join(@fixtures, "sink.bloccs")) <>
          "\n[schemas.\"MsOrder@1\"]\nid = \"text\"\n"

      assert {:error, [error]} = Parser.parse_node_string(toml)
      assert error.section == "[schemas]"
      assert error.message =~ "MsOrder@1.id: unknown type \"text\""
    end
  end

  describe "validation" do
    test "a network collects the schemas its node manifests declare" do
      network = parse!("ms_ok.bloccs")

      assert :ok = Validator.validate_network(network)
      assert Schemas.merged(network) |> Map.keys() == ~w(MsCustomer@1 MsOrder@1 MsRaw@1)
    end

    test "a declared schema satisfies :require_schemas without the registry" do
      assert Schema.lookup("MsOrder@1") == :error
      assert :ok = Validator.validate_network(parse!("ms_ok.bloccs"), require_schemas: true)
    end

    test "one name declared with different fields in two files is rejected" do
      assert {:error, issues} = Validator.validate_network(parse!("ms_conflict.bloccs"))

      assert [message] = messages(issues)
      assert message =~ "[schemas].MsOrder@1 is declared with different fields in"
      assert message =~ "ms_conflict.bloccs"
      assert message =~ "source.bloccs"
    end

    test "a field type that names an undeclared schema is rejected" do
      assert {:error, issues} = Validator.validate_network(parse!("ms_dangling.bloccs"))

      assert messages(issues) == [
               "[schemas].MsShipment@1 field carrier names MsCarrier@1, which no manifest declares"
             ]
    end

    test "a conflict with a schema declared in a subgraph's file is rejected" do
      assert {:error, issues} = Validator.validate_network(parse!("ms_parent.bloccs"))

      assert [message] = messages(issues)
      assert message =~ "[schemas].MsCustomer@1 is declared with different fields in"
      assert message =~ "ms_sub.bloccs"
      assert message =~ "source.bloccs"
    end
  end

  describe "runtime" do
    setup do
      network = parse!("ms_ok.bloccs")
      {:ok, sup} = Compiler.compile_and_load(network)
      start_supervised!(sup)

      test_pid = self()
      handler = "manifest-schemas-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:bloccs, :node, :stop],
        fn _event, _measurements, meta, _config ->
          if meta[:outcome] == :failed, do: send(test_pid, {:failed, meta[:node], meta[:reason]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      Router.register_sink(:ms_ok, :sink, :done, self())
      :ok
    end

    defp push(payload),
      do: Producer.push(Router.producer_name(:ms_ok, :source, :raw), payload)

    @order %{id: "o-1", total: 4900, tags: ["new"], buyer: %{name: "Ada"}}

    test "the declared schemas are not put in the global registry" do
      assert Schema.lookup("MsOrder@1") == :error
      assert Schema.lookup("MsCustomer@1") == :error
    end

    test "a payload that matches the declared schema is delivered" do
      push(@order)
      assert_receive {:bloccs_sink, _, :sink, _, @order}, 2000
    end

    test "a payload is checked against the declared schema, at the node that names it" do
      push(%{@order | total: "49.00"})

      assert_receive {:failed, :sink,
                      {:schema_mismatch, "MsOrder@1",
                       ["field total: expected :integer, got \"49.00\""]}},
                     2000
    end

    test "a nested schema and a list type are checked" do
      push(%{@order | buyer: %{name: 7}, tags: ["new", 2]})

      assert_receive {:failed, :sink, {:schema_mismatch, "MsOrder@1", reasons}}, 2000

      assert Enum.sort(reasons) == [
               "MsCustomer@1.field name: expected :string, got 7",
               "field tags[1]: expected :string, got 2"
             ]
    end
  end
end
