defmodule Esr.Resource.Workspace.SessionBindings do
  @moduledoc """
  Tracks the live `(workspace_uuid → MapSet<session_id>)` map and its
  inverse `(session_id → workspace_uuid)`. Ephemeral runtime state —
  NOT identity — so it sits outside the `Esr.Uri.Store` (which holds
  canonical entity rows + aliases).

  PR-2 (URI identity migration, 2026-05-12) extracted this concern
  from `Esr.Resource.Workspace.Registry`'s `state.session_index`
  field. The Registry is being deleted; session bindings have no
  natural home in the URI store, so they live here in a small
  dedicated GenServer.

  Public API mirrors the old Registry mutators 1-for-1:

    * `bind_session/2`
    * `unbind_session/1`
    * `sessions_for/1`
    * `delete_if_no_sessions/1` — atomic delete-workspace-if-empty
      gate; consults `Esr.Uri.Compat.workspace_by_uuid/1` and
      `workspace_delete_by_id/1` on its own (no Registry indirection).
  """

  @behaviour Esr.Role.State
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Public API ----------------------------------------------------------

  @spec bind_session(String.t(), String.t()) :: :ok | {:error, :workspace_gone}
  def bind_session(workspace_id, session_id)
      when is_binary(workspace_id) and is_binary(session_id),
      do: GenServer.call(__MODULE__, {:bind_session, workspace_id, session_id})

  @spec unbind_session(String.t()) :: :ok
  def unbind_session(session_id) when is_binary(session_id),
    do: GenServer.call(__MODULE__, {:unbind_session, session_id})

  @spec sessions_for(String.t()) :: [String.t()]
  def sessions_for(workspace_id) when is_binary(workspace_id),
    do: GenServer.call(__MODULE__, {:sessions_for, workspace_id})

  @doc """
  Atomic delete-if-empty gate. Returns:

    * `{:ok, :deleted}`        — workspace existed, was transient and unbound; deleted.
    * `{:ok, :not_transient}`  — workspace exists with transient=false; not eligible.
    * `{:ok, :has_sessions}`   — workspace exists, transient=true, but still bound.
    * `{:error, :not_found}`   — workspace doesn't exist.
  """
  @spec delete_if_no_sessions(String.t()) ::
          {:ok, :deleted | :not_transient | :has_sessions} | {:error, :not_found}
  def delete_if_no_sessions(workspace_id) when is_binary(workspace_id),
    do: GenServer.call(__MODULE__, {:delete_if_no_sessions, workspace_id})

  ## GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{by_ws: %{}, by_sid: %{}}}
  end

  @impl true
  def handle_call({:bind_session, ws_id, sid}, _from, state) do
    case Esr.Uri.Compat.workspace_by_uuid(ws_id) do
      {:ok, _ws} ->
        sids = Map.get(state.by_ws, ws_id, MapSet.new())
        state = %{
          state
          | by_ws: Map.put(state.by_ws, ws_id, MapSet.put(sids, sid)),
            by_sid: Map.put(state.by_sid, sid, ws_id)
        }

        {:reply, :ok, state}

      :not_found ->
        {:reply, {:error, :workspace_gone}, state}
    end
  end

  def handle_call({:unbind_session, sid}, _from, state) do
    state =
      case Map.pop(state.by_sid, sid) do
        {nil, _} ->
          state

        {ws_id, by_sid} ->
          sids = Map.get(state.by_ws, ws_id, MapSet.new()) |> MapSet.delete(sid)

          by_ws =
            if MapSet.size(sids) == 0,
              do: Map.delete(state.by_ws, ws_id),
              else: Map.put(state.by_ws, ws_id, sids)

          %{state | by_sid: by_sid, by_ws: by_ws}
      end

    {:reply, :ok, state}
  end

  def handle_call({:sessions_for, ws_id}, _from, state) do
    sids = state.by_ws |> Map.get(ws_id, MapSet.new()) |> MapSet.to_list()
    {:reply, sids, state}
  end

  def handle_call({:delete_if_no_sessions, ws_id}, _from, state) do
    case Esr.Uri.Compat.workspace_by_uuid(ws_id) do
      {:ok, ws} ->
        cond do
          not ws.transient ->
            {:reply, {:ok, :not_transient}, state}

          sessions_left?(state.by_ws, ws_id) ->
            {:reply, {:ok, :has_sessions}, state}

          true ->
            :ok = Esr.Uri.Compat.workspace_delete_by_id(ws_id)
            {:reply, {:ok, :deleted}, drop_workspace_from_state(state, ws_id)}
        end

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp sessions_left?(by_ws, ws_id) do
    case Map.get(by_ws, ws_id) do
      nil -> false
      %MapSet{} = ms -> MapSet.size(ms) > 0
    end
  end

  defp drop_workspace_from_state(state, ws_id) do
    sids =
      state.by_ws
      |> Map.get(ws_id, MapSet.new())
      |> MapSet.to_list()

    by_sid = Map.drop(state.by_sid, sids)
    by_ws = Map.delete(state.by_ws, ws_id)
    %{state | by_ws: by_ws, by_sid: by_sid}
  end
end
