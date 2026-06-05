defmodule Bloccs.Retry do
  @moduledoc """
  > #### Runtime internals {: .info}
  >
  > Infrastructure called by compiler-generated pipelines — not part of the
  > stable user API. You drive this through manifests, not by calling it directly;
  > signatures may change between minor versions.

  Retry policy evaluation for the runtime.

  Pure decision functions over a node's `[contract].retry` declaration:

      retry = { strategy = "exponential", max = 3, on = ["timeout"], base_ms = 100 }

  - `strategy` ∈ `"constant" | "linear" | "exponential"` (anything else → no backoff delay)
  - `max` — maximum number of *retries* (attempt 0 is the original delivery, so
    `max = 3` means up to 4 total attempts)
  - `on` — list of failure-reason tags to retry; empty/absent means "retry any
    transient failure"
  - `base_ms` — backoff base in ms (default #{100})

  Some failures are *permanent* — retrying cannot help — and are never retried
  regardless of policy: inbound schema mismatches, unknown ports, non-map
  payloads, and effect capability denials.
  """

  @default_base_ms 100
  @max_backoff_ms 30_000

  @typedoc "A parsed retry policy (or nil when none declared)."
  @type policy :: %{
          required(:strategy) => String.t(),
          required(:max) => non_neg_integer(),
          required(:on) => [String.t()],
          optional(:base_ms) => pos_integer() | nil
        }

  @doc """
  Should a message that failed with `reason` on its `attempt`-th try (0-based)
  be retried under `policy`?

  Returns `false` when no policy is declared, when `reason` is permanent, when
  `attempt` has already reached `policy.max`, or when `policy.on` is non-empty
  and doesn't list `reason`'s tag.
  """
  @spec retriable?(term(), policy() | nil, non_neg_integer()) :: boolean()
  def retriable?(_reason, nil, _attempt), do: false

  def retriable?(_reason, %{max: max}, attempt) when attempt >= max, do: false

  def retriable?(reason, %{on: on}, _attempt) do
    cond do
      permanent?(reason) -> false
      on in [nil, []] -> true
      true -> reason_tag(reason) in on
    end
  end

  @doc """
  Milliseconds to wait before the retry that follows `attempt` (0-based).

  Backoff grows by `strategy`, seeded at `base_ms`, capped at #{@max_backoff_ms}ms.
  """
  @spec backoff_ms(policy(), non_neg_integer()) :: non_neg_integer()
  def backoff_ms(policy, attempt) do
    base = Map.get(policy, :base_ms) || @default_base_ms

    raw =
      case Map.get(policy, :strategy) do
        "linear" -> base * (attempt + 1)
        "exponential" -> base * Integer.pow(2, attempt)
        _ -> base
      end

    min(raw, @max_backoff_ms)
  end

  @doc """
  Permanent failures: deterministic errors that retrying cannot fix. These are
  never retried even when a policy is declared.
  """
  @spec permanent?(term()) :: boolean()
  def permanent?({:schema_mismatch, _, _}), do: true
  def permanent?({:unknown_port, _}), do: true
  def permanent?({:payload_not_map, _}), do: true
  def permanent?(%Bloccs.Effects.Denied{}), do: true
  def permanent?(_), do: false

  @doc """
  The string tag used to match a failure reason against `policy.on`.

  - atom → its string form (`:timeout` → `"timeout"`)
  - tagged tuple → the tag (`{:node_crash, _}` → `"node_crash"`)
  - exception struct → `"exception"`
  - anything else → `"error"`
  """
  @spec reason_tag(term()) :: String.t()
  def reason_tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> Atom.to_string(tag)
      _ -> "error"
    end
  end

  def reason_tag(%{__exception__: true}), do: "exception"
  def reason_tag(_), do: "error"
end
