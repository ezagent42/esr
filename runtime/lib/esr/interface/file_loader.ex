defmodule Esr.Interface.FileLoader do
  @moduledoc """
  Yaml file loader contract: parse a file from disk, validate, and
  atomically swap the result into a paired SnapshotRegistry.

  Implementers in ESR (post-R4):
    - `Esr.Resource.Capability.FileLoader`
    - `Esr.Resource.SlashRoute.FileLoader`
    - `Esr.Resource.Workspace.Registry` (FYI: combined registry+loader today; may split later)
    - `Esr.Entity.User.FileLoader`
    - Future R5: `Esr.Entity.Agent.FileLoader`

  Loaders MUST be non-destructive on failure: a parse/validate error
  retains the previous snapshot.

  See `docs/notes/yaml-authoring-lessons.md` for the canonical 4-piece
  subsystem pattern (Registry + FileLoader + Watcher + Supervisor) and
  `docs/notes/structural-refactor-plan-r4-r11.md` §四-R4.
  """

  @doc "Load `path`, validate, and atomically swap into the paired registry."
  @callback load(path :: Path.t()) :: :ok | {:error, term()}
end
