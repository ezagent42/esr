defmodule Esr.Admin.Supervisor do
  @moduledoc """
  OTP Supervisor for the Admin subsystem.

  Spec §6.1. Strategy is `:rest_for_one` so that if the Dispatcher
  (first child) dies, the CommandQueue.Watcher is also restarted —
  otherwise the Watcher would keep casting into a transiently-missing
  Dispatcher, losing commands in the window before restart. If only
  the Watcher dies, the Dispatcher is unaffected.

  The `CommandQueue.Janitor` runs last: it has no runtime dependency
  on the Dispatcher or Watcher, but placing it at the tail means a
  Dispatcher crash restarts it too — that's fine, its state is just
  a single `Process.send_after/3` timer that re-arms on init.

  Started from `Esr.Application.start/2` AFTER
  `Esr.Resource.Capability.Supervisor` (Dispatcher checks capabilities during
  authorization) and AFTER `Esr.Resource.Workspace.Registry` (the
  `register_adapter` command validates workspace names at execution
  time).
  """

  @behaviour Esr.Role.OTP
  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Esr.Admin.Dispatcher, []},
      {Esr.Admin.CommandQueue.Watcher, []},
      {Esr.Admin.CommandQueue.Janitor, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
