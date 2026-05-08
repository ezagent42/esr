defmodule Esr.Interface.SnapshotRegistry do
  @moduledoc """
  Snapshot registry contract: bulk-load a complete dataset (typically from
  a yaml file) and serve reads against it. No per-entry register; the
  entire snapshot is replaced atomically by `load_snapshot/1`.

  Implementers in ESR (post-R4):
    - `Esr.Entity.User.Registry` (load_snapshot from users.yaml)
    - `Esr.Resource.Workspace.Registry` (load_from_file → load_snapshot)
    - `Esr.Resource.Capability.Grants` (load_snapshot from capabilities.yaml)
    - `Esr.Resource.SlashRoute.Registry` (load_snapshot from slash-routes.yaml)
    - Future R5: `Esr.Entity.Agent.Registry` (load_snapshot from agents.yaml)

  Pairs with `Esr.Interface.FileLoader` (the loader sub-module that parses
  the yaml and calls `load_snapshot/1`).

  See `docs/notes/structural-refactor-plan-r4-r11.md` §四-R4.
  """

  @doc """
  Atomically replace the in-memory snapshot. Implementers MUST guarantee
  that concurrent readers either see the entire previous snapshot or the
  entire new one (no partial state).
  """
  @callback load_snapshot(snapshot :: map()) :: :ok
end
