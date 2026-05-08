defmodule Esr.Interface.LiveRegistry do
  @moduledoc """
  Live-registration registry contract: per-entry register/unregister at
  runtime, in addition to the read APIs from `Esr.Interface.LookupRegistry`.

  Live registries typically back ETS tables or Elixir's kernel `Registry`
  and are populated incrementally as actors come up. Examples:
    - `Esr.Entity.Registry` (actor_id → pid; auto-cleanup on pid death)
    - `Esr.Resource.AdapterSocket.Registry` (sid → socket; soft-offline)
    - Future R5: `Esr.Resource.ChatScope.Registry` (chat → sid)

  `unregister` is best-effort and returns `:ok` even if the key wasn't
  registered (idempotent).

  See `docs/notes/structural-refactor-plan-r4-r11.md` §四-R4.
  """

  @doc "Register a value under `key`. `{:error, _}` if key already taken under unique-strategy."
  @callback register(key :: term(), value :: term()) :: :ok | {:error, term()}

  @doc "Remove the binding for `key`. Always `:ok` (idempotent)."
  @callback unregister(key :: term()) :: :ok
end
