defmodule Esr.ActorQuery do
  @moduledoc """
  Peer lookup. Three functions; three ETS indexes in `Esr.Entity.Registry`.

  Locked decision Q5.1 (Feishu 2026-05-07): NO predicate DSL, NO scope
  enum, NO multi-attribute query language. Cap-based discovery is out of
  scope (Q5.5).

  ## Index map

    * Index 1 — `actor_id → pid`            via `Elixir.Registry`
      (consulted by `find_by_id/1`).
    * Index 2 — `{session_id, name} → pid`  via `:esr_actor_name_index`
      (consulted by `find_by_name/2`).
    * Index 3 — `{session_id, role} → [pid]` via `:esr_actor_role_index`
      (consulted by `list_by_role/2`; bag table — multi-instance same role).

  ## Monitor pattern

  ActorQuery returns live pids at the moment of the call. A pid can die
  between the return and the first send. Callers that need a stable
  reference should monitor immediately:

      case Esr.ActorQuery.find_by_name(sid, name) do
        {:ok, pid} ->
          _ref = Process.monitor(pid)
          send(pid, msg)
        :not_found ->
          handle_missing()
      end

  `list_by_role/2` reads from a `:bag` table. In the narrow window
  between a pid dying and the Registry DOWN handler processing, a dead
  pid may appear. Use `Process.alive?/1` or the monitor-before-send
  pattern to handle this safely.
  """

  @name_index :esr_actor_name_index
  @role_index :esr_actor_role_index

  @doc """
  Find a peer by its operator-facing display name within a session.

  Searches the `:esr_actor_name_index` ETS table (`:set` strategy;
  enforces uniqueness at insert time via `:ets.insert_new/2`).

  Returns `{:ok, pid}` when exactly one live registration exists.
  Returns `:not_found` when no entry exists for `{session_id, name}`.
  """
  @spec find_by_name(session_id :: String.t(), name :: String.t()) ::
          {:ok, pid()} | :not_found
  def find_by_name(session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case :ets.lookup(@name_index, {session_id, name}) do
      [{_key, {pid, _actor_id}}] when is_pid(pid) -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc """
  List all live pids for a given role within a session.

  Searches the `:esr_actor_role_index` ETS table (`:bag` strategy;
  multiple values per `{session_id, role}` key support multi-instance
  same role).

  Returns a (possibly empty) list of pids. Ordering is not guaranteed.
  The caller chooses the selection strategy (`List.first/1`, fan-out, etc.).
  """
  @spec list_by_role(session_id :: String.t(), role :: atom()) :: [pid()]
  def list_by_role(session_id, role)
      when is_binary(session_id) and is_atom(role) do
    @role_index
    |> :ets.lookup({session_id, role})
    |> Enum.map(fn {_key, {pid, _actor_id}} -> pid end)
  end

  @doc """
  Find a peer by its UUID actor_id. Searches across all sessions.

  Delegates to `Esr.Entity.Registry.lookup/1` (Index 1: actor_id → pid).

  Returns `{:ok, pid}` or `:not_found`. Use for cross-references where
  the actor_id is stored in InstanceRegistry or in another actor's
  persisted state and must survive restarts (actor_id is stable; pid
  changes on restart).
  """
  @spec find_by_id(actor_id :: String.t()) :: {:ok, pid()} | :not_found
  def find_by_id(actor_id) when is_binary(actor_id) do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end
end
