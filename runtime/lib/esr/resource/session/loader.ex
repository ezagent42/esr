defmodule Esr.Resource.Session.Loader do
  @moduledoc """
  Boot-time Task that runs `Esr.Resource.Session.FileLoader.populate_uri_store/0`
  once and exits :normal. Restart=:transient — exits successfully even
  when the populate call returns an error tuple (logged inside the
  loader; not worth crashing the whole app over a stale session).

  PR-3 (URI identity migration, 2026-05-12): replaces the deleted
  `Esr.Resource.Session.Registry`'s `init/1` boot-scan side-effect.
  Must run AFTER `Esr.Uri.Store` is up so put_entity calls succeed.
  """

  use Task, restart: :transient
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    _ = Esr.Resource.Session.FileLoader.populate_uri_store()
    :ok
  end
end
