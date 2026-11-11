defmodule Bloccs.Integration.GenericPortsFixtures do
  @moduledoc """
  Node impls for the generic-ports prototype. `Audit` and `Stamp` are written
  once with a `$T` port bounded by `Keyed@1`; the rest are pass-through sources
  and sinks with concrete schemas.
  """

  defmodule Pass do
    @moduledoc false
    defmacro __using__(manifest: manifest, port: port) do
      quote do
        use Bloccs.Node, manifest: unquote("../fixtures/generic_ports/" <> manifest)
        def transform(data, _ctx), do: {:ok, data}
        def execute(data, _ctx), do: {:emit, unquote(port), data}
      end
    end
  end

  defmodule OrderSource do
    @moduledoc false
    use Pass, manifest: "order_source.bloccs", port: :out
  end

  defmodule InvoiceSource do
    @moduledoc false
    use Pass, manifest: "invoice_source.bloccs", port: :out
  end

  defmodule AnonSource do
    @moduledoc false
    use Pass, manifest: "anon_source.bloccs", port: :out
  end

  defmodule NumIdSource do
    @moduledoc false
    use Pass, manifest: "numid_source.bloccs", port: :out
  end

  # Its out schema is declared nowhere: not in a network, not in the registry.
  defmodule UndeclaredSource do
    @moduledoc false
    use Pass, manifest: "undeclared_source.bloccs", port: :out
  end

  defmodule Stamp do
    @moduledoc false
    use Pass, manifest: "stamp.bloccs", port: :out
  end

  defmodule OrderSink do
    @moduledoc false
    use Pass, manifest: "order_sink.bloccs", port: :done
  end

  defmodule InvoiceSink do
    @moduledoc false
    use Pass, manifest: "invoice_sink.bloccs", port: :done
  end

  defmodule Audit do
    @moduledoc "Needs only `id`; passes every other field through."
    use Bloccs.Node, manifest: "../fixtures/generic_ports/audit.bloccs"
    def transform(data, _ctx), do: {:ok, Map.put(data, :audited, "audit:" <> data.id)}
    def execute(data, _ctx), do: {:emit, :out, data}
  end
end
