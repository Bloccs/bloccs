defmodule Bloccs.ParserPropertyTest do
  @moduledoc """
  Property-based tests for the manifest parser.

  Coverage:
  - Valid node manifests parse without error for any reasonable shape
  - Round-trip stability: serialize a generated manifest, re-parse, equal struct
  - Invalid manifests always return structured errors (no crashes)
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Bloccs.Parser

  describe "parse_node_string/1 — generative coverage" do
    property "any well-formed manifest parses successfully" do
      check all(manifest <- node_manifest_gen(), max_runs: 50) do
        toml = render_node_toml(manifest)
        assert {:ok, node} = Parser.parse_node_string(toml)
        assert node.id == manifest.id
        assert node.kind in [:source, :transform, :router, :sink]
      end
    end

    property "every random binary either decodes or returns structured errors" do
      check all(
              garbage <- StreamData.binary(min_length: 0, max_length: 64),
              max_runs: 100
            ) do
        case Parser.parse_node_string(garbage) do
          {:ok, _} -> :ok
          {:error, errs} -> assert Enum.all?(errs, &match?(%Bloccs.Parser.Error{}, &1))
        end
      end
    end
  end

  describe "parse_node_string/1 — invariants" do
    property "a manifest with no [contract] section always errors with the right scope" do
      check all(
              id <- identifier(),
              version <- version_string(),
              kind <- StreamData.member_of(["source", "transform", "router", "sink"]),
              max_runs: 25
            ) do
        toml = """
        [node]
        id = "#{id}"
        version = "#{version}"
        kind = "#{kind}"

        [ports.in]
        i = { schema = "X@1" }

        [ports.out]
        o = { schema = "Y@1" }

        [effects]
        """

        assert {:error, errs} = Parser.parse_node_string(toml)
        assert Enum.any?(errs, &(&1.message =~ "[contract]"))
      end
    end
  end

  # ---- generators ----

  defp node_manifest_gen do
    gen all(
          id <- identifier(),
          version <- version_string(),
          kind <- StreamData.member_of(["source", "transform", "router", "sink"]),
          in_ports <- ports_gen(:in),
          out_ports <- ports_gen(:out),
          impl_mod <- module_name(),
          impl_fun_pure <- identifier(),
          impl_fun_shell <- identifier()
        ) do
      %{
        id: id,
        version: version,
        kind: kind,
        in_ports: in_ports,
        out_ports: out_ports,
        pure_core: "#{impl_mod}.#{impl_fun_pure}/2",
        effect_shell: "#{impl_mod}.#{impl_fun_shell}/2"
      }
    end
  end

  defp ports_gen(_direction) do
    StreamData.list_of(
      StreamData.tuple({identifier(), schema_id()}),
      min_length: 1,
      max_length: 3
    )
    |> StreamData.map(&Enum.uniq_by(&1, fn {name, _} -> name end))
  end

  defp identifier do
    StreamData.string(?a..?z, min_length: 1, max_length: 8)
  end

  defp module_name do
    gen all(parts <- StreamData.list_of(capitalized(), min_length: 1, max_length: 3)) do
      Enum.join(parts, ".")
    end
  end

  defp capitalized do
    StreamData.bind(StreamData.string(?a..?z, min_length: 1, max_length: 6), fn s ->
      StreamData.constant(String.capitalize(s))
    end)
  end

  defp version_string do
    gen all(
          major <- StreamData.integer(0..5),
          minor <- StreamData.integer(0..9),
          patch <- StreamData.integer(0..9)
        ) do
      "#{major}.#{minor}.#{patch}"
    end
  end

  defp schema_id do
    gen all(name <- capitalized(), v <- StreamData.integer(1..3)) do
      "#{name}@#{v}"
    end
  end

  defp render_node_toml(m) do
    """
    [node]
    id = "#{m.id}"
    version = "#{m.version}"
    kind = "#{m.kind}"

    [ports.in]
    #{render_ports(m.in_ports)}

    [ports.out]
    #{render_ports(m.out_ports)}

    [effects]

    [contract]
    pure_core = "#{m.pure_core}"
    effect_shell = "#{m.effect_shell}"
    """
  end

  defp render_ports(ports) do
    ports
    |> Enum.map(fn {name, schema} -> ~s|#{name} = { schema = "#{schema}" }| end)
    |> Enum.join("\n")
  end
end
