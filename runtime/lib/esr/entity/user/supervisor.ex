defmodule Esr.Entity.User.Supervisor do
  @moduledoc """
  Supervises the esr-user subsystem.

  PR-1 (URI identity migration, 2026-05-12): User.Registry + User.NameIndex
  deleted; their ETS tables replaced by entries in `:esr_uri_store`
  (owned by `Esr.Uri.Store`, started before this supervisor by the
  Application). Only the file Watcher remains here.

  - `Esr.Entity.User.Watcher` — `users.yaml` reload watcher.
    On boot and on file change it invokes
    `Esr.Entity.User.FileLoader.load/1`, which populates the URI store.
  """

  @behaviour Esr.Role.OTP
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Esr.Paths.users_yaml())

    children = [
      {Esr.Entity.User.Watcher, path: path}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
