defmodule Bloccs.EffectError do
  @moduledoc """
  A structured terminal failure, delivered to a `Bloccs.call/4` / `cast/4` caller
  as the `{:error, t()}` result when a request fails before it can reply.

  Without this, a failed request would surface only as a `call/4` timeout — the
  caller could not tell "failed" from "slow". The struct names *where* on the
  request's path the failure occurred:

  - `:validate` — the payload failed a node's inbound `Name@N` schema.
  - `:execute`  — the node's `pure_core` / `effect_shell` raised, returned
    `{:error, _}`, or exceeded its `timeout_ms`.
  - `:dispatch` — the node produced a result but delivering it downstream failed.

  `reason` is the underlying failure term (an exception struct, a schema-error
  tuple, `:timeout`, a `{:dispatch_failed, _}` tuple, …). `attempt` is the retry
  attempt the failure occurred on (`0` for the first).

  Only terminal failures of a node on the request's 1:1 trace are reported — a
  failure that is retried is not (a later attempt may still succeed and reply).
  Correlation does not survive a `[batch]`/`[join]` (which mint a fresh
  `trace_id`); see `Bloccs.Collector`.
  """

  @type phase :: :validate | :execute | :dispatch

  @type t :: %__MODULE__{
          network: atom(),
          node: atom(),
          phase: phase(),
          attempt: non_neg_integer(),
          reason: term()
        }

  @enforce_keys [:network, :node, :phase, :attempt, :reason]
  defstruct [:network, :node, :phase, :attempt, :reason]
end
