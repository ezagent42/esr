defmodule Esr.Routing.Supervisor do
  @moduledoc """
  OTP Supervisor for the Routing subsystem (spec §6.5).

  Started from `Esr.Application.start/2` AFTER `Esr.Admin.Supervisor`
  because `Esr.Routing.SessionRouter` casts to `Esr.Admin.Dispatcher`
  for every slash command — the Dispatcher must be registered before
  the Router begins accepting inbound msg_received events.

  Strategy is `:one_for_one`. Only the `SessionRouter` lives here in
  Task 17; Task 18 will keep the FileSystem subscription inside the
  SessionRouter itself (not a sibling child) so a watcher crash also
  restarts the Router's in-memory routing/branches maps cleanly.
  """

  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Esr.Routing.SessionRouter, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
