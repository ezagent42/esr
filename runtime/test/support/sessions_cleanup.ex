defmodule Esr.TestSupport.SessionsCleanup do
  @moduledoc """
  Shared ExUnit setup helper: register an `on_exit` that terminates
  every child still tracked under the app-level
  `Esr.SessionsSupervisor`. Used by integration tests that spawn
  sessions under the shared supervisor and need a guaranteed wipe
  regardless of whether the test body crashed mid-flight.

  Usage:

      setup :wipe_sessions_on_exit
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec wipe_sessions_on_exit(map()) :: :ok
  def wipe_sessions_on_exit(_ctx) do
    on_exit(&wipe_all/0)
    :ok
  end

  @doc "Terminate every child currently under `Esr.SessionsSupervisor`."
  @spec wipe_all() :: :ok
  def wipe_all do
    case Process.whereis(Esr.SessionsSupervisor) do
      nil ->
        :ok

      pid ->
        for {_, child, _, _} <- DynamicSupervisor.which_children(pid) do
          if is_pid(child), do: DynamicSupervisor.terminate_child(pid, child)
        end

        :ok
    end
  end
end
