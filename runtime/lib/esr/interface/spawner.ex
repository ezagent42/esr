defmodule Esr.Interface.Spawner do
  @moduledoc """
  Spawner contract: read a Session declaration (kind + topology) and
  instantiate a runtime Scope subtree by spawning its member entities
  and wiring neighbor refs.

  Implementers in ESR (post-R6 — only one today):
    - `Esr.Session.AgentSpawner` (R6: spawns agents.yaml-declared Sessions)

  Future Phase 4 implementers:
    - `Esr.Session.GroupChatSpawner` (group-chat Scope kind)
    - `Esr.Session.DaemonSpawner` (currently implicit in `Esr.Application`)

  See `docs/notes/structural-refactor-plan-r4-r11.md` §四-R6 for the
  AgentSpawner extraction from Esr.Scope.Router.
  """

  @doc """
  Spawn a Scope subtree from a declaration. `decl` is the Session
  declaration (e.g., the agent entry in agents.yaml). `params` carries
  per-instance data (session_id, dir, principal). `ctx` carries
  cross-cutting state (neighbor refs to populate).

  Returns the supervisor pid of the spawned Scope subtree.
  """
  @callback spawn(decl :: map(), params :: map(), ctx :: map()) ::
              {:ok, scope_pid :: pid()} | {:error, term()}

  @doc "Tear down a Scope subtree by its scope_id."
  @callback terminate(scope_id :: binary(), reason :: term()) :: :ok
end
