defmodule Esr.Slash.CleanupRendezvous do
  @moduledoc """
  Phase 2 PR-2.3a: cleanup-signal rendezvous between
  `Esr.Commands.Scope.BranchEnd` (the Task awaiting an MCP-side
  ack) and the `session.signal_cleanup` MCP tool inbound (delivered
  via `Esr.Entity.Server.build_emit_for_tool/3`).

  Pre-PR-2.3a this responsibility lived inside `Esr.Admin.Dispatcher`
  alongside dispatch + permission check + queue file state machine.
  Per the Phase 2 spec subagent-review (2026-05-05), Dispatcher
  conflated 4 concerns; cleanup_signal rendezvous is the simplest of
  them and breaks out cleanly into this small module.

  ## API

    * `register_cleanup(session_id, task_pid)` — called by BranchEnd
      before it blocks on `receive`. Stores `session_id → task_pid` so
      an inbound MCP signal can be forwarded.
    * `deregister_cleanup(session_id)` — called by BranchEnd on
      timeout / after consuming the signal so the table doesn't
      accumulate stale entries.
    * `signal_cleanup(session_id, status, details)` — called by the
      MCP tool path in `Esr.Entity.Server.build_emit_for_tool`. Looks
      up the registered Task pid and forwards
      `{:cleanup_signal, status, details}` to it. No-op (with a log
      warning) if no waiter is registered.

  ## Lifecycle

  Started under `Esr.Application` BEFORE `Esr.Admin.Supervisor` so
  callsites in BranchEnd / Server can find it during boot. Because
  each entry is short-lived (registered on BranchEnd entry, removed
  on signal-or-timeout), the in-memory map in GenServer state is
  fine — there's no fan-out where ETS would matter.

  ## Why DI here

  Per North Star: pulling rendezvous out of `Esr.Admin.*` lets future
  plugins introduce their own long-running operations (e.g. a /sync
  command that blocks on a sidecar response) without going through
  the admin dispatcher. They'd register their own waiters here under
  a chosen key shape — the rendezvous is generic.
  """

  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Register the current process as the Task awaiting a `:cleanup_signal`
  for `session_id`. Overwrites any existing registration.
  """
  @spec register_cleanup(String.t(), pid()) :: :ok
  def register_cleanup(session_id, task_pid)
      when is_binary(session_id) and is_pid(task_pid) do
    GenServer.cast(__MODULE__, {:register_cleanup, session_id, task_pid})
  end

  @doc """
  Deregister a pending cleanup. Idempotent: removing a missing entry
  is a no-op.
  """
  @spec deregister_cleanup(String.t()) :: :ok
  def deregister_cleanup(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:deregister_cleanup, session_id})
  end

  @doc """
  Forward `{:cleanup_signal, status, details}` to the Task registered
  for `session_id`. If no Task is registered, logs a warning and
  drops. If the registered Task is dead, also logs and drops. The
  registration is removed regardless.
  """
  @spec signal_cleanup(String.t(), String.t(), map()) :: :ok
  def signal_cleanup(session_id, status, details \\ %{})
      when is_binary(session_id) and is_binary(status) do
    GenServer.cast(__MODULE__, {:signal, session_id, status, details})
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_cast({:register_cleanup, session_id, task_pid}, state) do
    {:noreply, put_in(state.pending[session_id], task_pid)}
  end

  def handle_cast({:deregister_cleanup, session_id}, state) do
    {:noreply, %{state | pending: Map.delete(state.pending, session_id)}}
  end

  def handle_cast({:signal, session_id, status, details}, state) do
    case Map.pop(state.pending, session_id) do
      {nil, _} ->
        Logger.warning(
          "cleanup_rendezvous: signal for session_id=#{session_id} status=#{status} " <>
            "with no pending waiter (race or stray signal)"
        )

        {:noreply, state}

      {task_pid, rest} when is_pid(task_pid) ->
        if Process.alive?(task_pid) do
          send(task_pid, {:cleanup_signal, status, details})
        else
          Logger.warning(
            "cleanup_rendezvous: signal for session_id=#{session_id} found dead waiter — dropping"
          )
        end

        {:noreply, %{state | pending: rest}}
    end
  end
end
