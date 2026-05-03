defmodule Esr.Entity.User.Supervisor do
  @moduledoc """
  Supervises the esr-user subsystem (PR-21a):

  - `Esr.Entity.User.Registry` — ETS snapshot
  - `Esr.Entity.User.Watcher` — `users.yaml` reload watcher (depends on
    Registry being up so its `init/1` initial-load lands in real ETS)
  """

  @behaviour Esr.Role.OTP
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Esr.Paths.users_yaml())

    children = [
      Esr.Entity.User.Registry,
      {Esr.Entity.User.Watcher, path: path}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
