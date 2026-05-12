defmodule Esr.Resource.Workspace.Loader do
  @moduledoc """
  Boot-time Task that runs `Esr.Resource.Workspace.FileLoader.populate_uri_store/0`
  once and exits :normal. Restart=:transient — exits successfully even
  when the populate call returns an error tuple (logged inside the
  loader; not worth crashing the whole app over a stale workspace).

  PR-2 (URI identity migration, 2026-05-12): replaces the deleted
  `Esr.Resource.Workspace.Registry`'s `init/1` boot-scan side-effect.
  Must run BEFORE `Esr.Resource.Workspace.Bootstrap` (which calls
  `Esr.Uri.Compat.workspace_put/1` and assumes the URI store has
  the snapshot already loaded).
  """

  use Task, restart: :transient
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    _ = Esr.Resource.Workspace.FileLoader.populate_uri_store()
    :ok
  end
end
