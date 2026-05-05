defmodule Esr.Admin.Supervisor do
  @moduledoc """
  OTP Supervisor for the Admin subsystem.

  PR-2.3b-2 deleted `Esr.Admin.Dispatcher`; the unified dispatch
  path now flows through `Esr.Entity.SlashHandler` (chat) and
  `Esr.Admin.CommandQueue.Watcher → SlashHandler.dispatch_command/2`
  (admin queue files).

  Children:
    - `CommandQueue.Watcher` — file system watcher on
      `<admin_queue>/pending/`. Dispatches to SlashHandler.
    - `CommandQueue.Janitor` — periodic cleanup of stale
      completed/failed entries.

  Strategy `:rest_for_one`: if Watcher dies, Janitor restarts too
  (cheap; janitor's state is one `Process.send_after/3` timer).

  Started from `Esr.Application.start/2` AFTER
  `Esr.Resource.Capability.Supervisor` (SlashHandler checks
  capabilities during authorization) and AFTER
  `Esr.Resource.Workspace.Registry` (register_adapter validates
  workspace names at execution time).
  """

  @behaviour Esr.Role.OTP
  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Esr.Admin.CommandQueue.Watcher, []},
      {Esr.Admin.CommandQueue.Janitor, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
