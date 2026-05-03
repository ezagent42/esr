defmodule Esr.Interface.LookupRegistry do
  @moduledoc """
  Read-only registry contract: any module that holds a key→value mapping
  and supports lookup by key implements this Interface.

  Implementers in ESR (post-R4):
    - `Esr.Entity.Registry` (actor_id → pid)
    - `Esr.Entity.User.Registry` (username → User.t)
    - `Esr.Resource.Workspace.Registry` (name → Workspace.t)
    - `Esr.Resource.Capability.Grants` (principal → permissions)
    - `Esr.Resource.SlashRoute.Registry` (slash text → route data)
    - `Esr.Resource.DeadLetter.Queue` (entry_id → entry)
    - `Esr.Resource.AdapterSocket.Registry` (sid → socket binding)

  See `docs/notes/structural-refactor-plan-r4-r11.md` §三 for the full
  audit of registry shapes and §四-R4 for this Interface's introduction.

  Sub-Interfaces extend this:
    - `Esr.Interface.LiveRegistry` adds `register/2`, `unregister/1`
    - `Esr.Interface.SnapshotRegistry` adds `load_snapshot/1`
  """

  @doc "Look up a value by key. `:error` (not `:not_found`) on miss — see §A1 normalization."
  @callback lookup(key :: term()) :: {:ok, value :: term()} | :error

  @doc "Enumerate all `{key, value}` pairs currently registered."
  @callback list() :: [{key :: term(), value :: term()}]
end
