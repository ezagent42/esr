defmodule Esr.Admin.Dispatcher do
  @moduledoc """
  Stub Dispatcher for the Admin subsystem (spec §6.2).

  The full execution flow — capability check → pending→processing
  move → Task.start → `{:command_result, id, result}` handling →
  processing→completed/failed move — arrives in Tasks 14 / 14b of the
  dev-prod-isolation plan. For DI-5 Task 10 the Dispatcher is only
  wired into the supervision tree so downstream callers
  (CommandQueue.Watcher, SessionRouter) can cast into a registered
  name. All received commands are logged and dropped.
  """
  use GenServer
  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_cast({:execute, command, _reply_to}, state) do
    Logger.warning(
      "admin.dispatcher: stub — ignoring command #{inspect(command)}"
    )

    {:noreply, state}
  end
end
