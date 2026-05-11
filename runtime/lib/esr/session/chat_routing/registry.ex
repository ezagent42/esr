defmodule Esr.Session.ChatRouting.Registry do
  @moduledoc """
  Chat-scope routing registry — `(chat_id, app_id) → session_id`.

  Split from `Esr.Resource.ChatScope.Registry` (R5) per the cleanup-PR spec
  rev-3 §0: chat-routing concerns live here; URI-uniqueness concerns live
  in `Esr.Session.NameIndex.Registry`.

  ## Responsibilities

  Exactly one current session per `(chat_id, app_id)` slot, plus an
  attached set for `/session:switch`.

  ## ETS shape (unified, PR-3 Task 3.3b)

  Single shape: `{key, %{current: sid | nil, attached: MapSet.t()}}`.
  The legacy 3-tuple `{key, sid, refs}` shape and its `register_session/3`
  writer were deleted in PR-3 Task 3.3b (spec rev-3 §4.5) — FAA no longer
  reaches into peer refs through ETS; it looks up sid via
  `current_session/2` and the FCP pid via
  `Esr.ActorQuery.fcp_for_session/1`.

  Public API:
    - `attach_session/3`        — attach a session UUID; sets as current if first
    - `detach_session/3`        — remove specific sid from a scope
    - `detach_session_by_id/1`  — remove sid from every scope it appears in
    - `current_session/2`       — return current session UUID or :not_found
    - `list_sessions/2`         — list all attached session UUIDs
    - `set_current_session/3`   — promote attached sid to current
    - `set_default_workspace/3` / `get_default_workspace/2` /
      `clear_default_workspace/2`
    - `reload/0`                — re-read attached state from disk

  Attached state is persisted to `$ESRD_HOME/$ESR_INSTANCE/chat_attached.yaml`
  on every attach/detach when `ESRD_HOME` is explicitly set. This guard prevents
  test runs (which share the default ~/.esrd path) from polluting disk state.

  ## ETS layout

  Two named, protected `:set` tables, owned by this GenServer.
  Reads run directly from the caller process, bypassing the GenServer
  mailbox; writes route through the owner (handle_call) so consistency
  with the in-memory `sessions` map is preserved.
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  # ETS index for (chat_id, app_id) → %{current, attached} entry.
  @ets_table :esr_session_chat_routing

  # T4.8: default workspace index — (chat_id, app_id) → workspace_uuid.
  @ets_default_workspace :esr_session_chat_routing_default_workspace

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Attach a session UUID to this `(chat_id, app_id)` scope.

  If this is the first attached session, it becomes the current session.
  Re-attaching an already-attached UUID is idempotent. State is persisted
  to disk after every attach when ESRD_HOME is set.
  """
  @spec attach_session(String.t(), String.t(), String.t()) :: :ok
  def attach_session(chat_id, app_id, session_uuid)
      when is_binary(chat_id) and is_binary(app_id) and is_binary(session_uuid) do
    GenServer.call(__MODULE__, {:attach_session, chat_id, app_id, session_uuid})
  end

  @doc """
  Detach a session UUID from this `(chat_id, app_id)` scope.

  If the detached session was current, the next remaining session becomes
  current (order undefined). If the set is empty after detach, current
  becomes nil. Idempotent on unknown UUIDs. State is persisted to disk when ESRD_HOME is set.
  """
  @spec detach_session(String.t(), String.t(), String.t()) :: :ok
  def detach_session(chat_id, app_id, session_uuid)
      when is_binary(chat_id) and is_binary(app_id) and is_binary(session_uuid) do
    GenServer.call(__MODULE__, {:detach_session, chat_id, app_id, session_uuid})
  end

  @doc """
  Return the current (attached-current) session UUID for this chat.

  Direct ETS read — runs in the caller process with no GenServer hop.
  Returns `{:ok, sid}` when a current session is set, `:not_found` otherwise.
  """
  @spec current_session(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def current_session(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{current: nil}}] -> :not_found
      [{_, %{current: sid}}] when is_binary(sid) -> {:ok, sid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Return the list of all attached session UUIDs for this chat.

  Direct ETS read — runs in the caller process with no GenServer hop.
  Order of returned list is undefined (MapSet iteration order).
  """
  @spec list_sessions(String.t(), String.t()) :: [String.t()]
  def list_sessions(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{attached: set}}] -> MapSet.to_list(set)
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Promote `session_uuid` to the chat-current session for this `(chat_id,
  app_id)` slot. The UUID must already be in the attached set.

  Used by `/session:switch session=<uuid>` to flip the chat's current
  session without unbinding the others. Idempotent when `session_uuid`
  is already current.

  Returns `:ok` on success, `{:error, :not_attached}` if the UUID has
  not been attached to this chat.
  """
  @spec set_current_session(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_attached}
  def set_current_session(chat_id, app_id, session_uuid)
      when is_binary(chat_id) and is_binary(app_id) and is_binary(session_uuid) do
    GenServer.call(__MODULE__, {:set_current_session, chat_id, app_id, session_uuid})
  end

  @doc """
  Detach a session UUID from every `(chat_id, app_id)` scope it currently
  occupies — used on session teardown when the caller only has a sid.

  Replaces the legacy `unregister_session/1` API (deleted in Task 3.3b)
  with a single semantically-named helper that walks the ETS table by
  sid value rather than depending on the in-memory `sessions` map.

  Semantics:
    * For each row keyed by `{chat_id, app_id}`:
      * Remove `sid` from `attached`.
      * If `current == sid`, promote the first remaining attached UUID
        (or set `current` to nil when the attached set empties).
      * Delete the row entirely if both `current` becomes nil AND
        `attached` is empty.

  Persists to disk when `ESRD_HOME` is set. Idempotent (no-op when sid
  appears nowhere). Also releases the URI claim via
  `Esr.Session.NameIndex.Registry.release_uri/1` for parity with the
  legacy contract — tolerates NameIndex not being started.
  """
  @spec detach_session_by_id(String.t()) :: :ok
  def detach_session_by_id(sid) when is_binary(sid) do
    result = GenServer.call(__MODULE__, {:detach_session_by_id, sid})
    _ = safe_release(sid)
    result
  end

  @doc """
  Reload attached state from disk. Clears the `@ets_table` entries
  and repopulates from `chat_attached.yaml`.

  Called when `ESRD_HOME` is set and used in persistence tests.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  defp safe_release(session_id) do
    try do
      Esr.Session.NameIndex.Registry.release_uri(session_id)
    catch
      :exit, _ -> :error
    rescue
      ArgumentError -> :error
    end
  end

  @doc """
  Set the default workspace UUID for a `(chat_id, app_id)` slot. New
  sessions originating from this chat will resolve to this workspace
  unless overridden at /new-session time.
  """
  @spec set_default_workspace(String.t(), String.t(), String.t()) :: :ok
  def set_default_workspace(chat_id, app_id, workspace_id)
      when is_binary(chat_id) and is_binary(app_id) and is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:set_default_workspace, chat_id, app_id, workspace_id})
  end

  @doc """
  Direct ETS read — runs in caller process. Returns `{:ok, uuid}` or `:not_found`.
  """
  @spec get_default_workspace(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def get_default_workspace(chat_id, app_id) do
    case :ets.lookup(@ets_default_workspace, {chat_id, app_id}) do
      [{_k, uuid}] -> {:ok, uuid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Clear the default workspace for a `(chat_id, app_id)` slot. Idempotent.
  """
  @spec clear_default_workspace(String.t(), String.t()) :: :ok
  def clear_default_workspace(chat_id, app_id)
      when is_binary(chat_id) and is_binary(app_id) do
    GenServer.call(__MODULE__, {:clear_default_workspace, chat_id, app_id})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ets_default_workspace, [:named_table, :set, :protected, read_concurrency: true])

    state = %{sessions: %{}, chat_to_session: %{}, chat_to_default_workspace_id: %{}}

    # Load persisted attached-set from disk on boot.
    # Guard on ESRD_HOME being explicitly set — prevents test runs sharing
    # the default ~/.esrd path from loading stale state written by prior runs.
    if System.get_env("ESRD_HOME") do
      load_attached_from_disk()
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Clear chat-index entries (not default workspace), then reload from disk.
    # Only meaningful when ESRD_HOME is set.
    :ets.delete_all_objects(@ets_table)

    if System.get_env("ESRD_HOME") do
      load_attached_from_disk()
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:attach_session, chat_id, app_id, uuid}, _from, state) do
    key = {chat_id, app_id}

    slot =
      case :ets.lookup(@ets_table, key) do
        [{_, %{} = s}] -> s
        _ -> %{current: nil, attached: MapSet.new()}
      end

    new_attached = MapSet.put(slot.attached, uuid)
    new_current = slot.current || uuid
    :ets.insert(@ets_table, {key, %{current: new_current, attached: new_attached}})

    persist_attached_to_disk()
    {:reply, :ok, state}
  end

  def handle_call({:set_current_session, chat_id, app_id, uuid}, _from, state) do
    key = {chat_id, app_id}

    reply =
      case :ets.lookup(@ets_table, key) do
        [{_, %{attached: set} = slot}] ->
          if MapSet.member?(set, uuid) do
            :ets.insert(@ets_table, {key, %{slot | current: uuid}})
            persist_attached_to_disk()
            :ok
          else
            {:error, :not_attached}
          end

        [] ->
          {:error, :not_attached}
      end

    {:reply, reply, state}
  end

  def handle_call({:detach_session, chat_id, app_id, uuid}, _from, state) do
    key = {chat_id, app_id}

    case :ets.lookup(@ets_table, key) do
      [{_, %{} = slot}] ->
        new_attached = MapSet.delete(slot.attached, uuid)

        new_current =
          cond do
            slot.current != uuid -> slot.current
            MapSet.size(new_attached) == 0 -> nil
            true -> MapSet.to_list(new_attached) |> List.first()
          end

        :ets.insert(@ets_table, {key, %{current: new_current, attached: new_attached}})

      _ ->
        :ok
    end

    persist_attached_to_disk()
    {:reply, :ok, state}
  end

  def handle_call({:detach_session_by_id, sid}, _from, state) do
    # Walk every ETS row, remove `sid` from each entry. Unified shape
    # only after Task 3.3b deletion of register_session/3.
    Enum.each(:ets.tab2list(@ets_table), fn
      {{_c, _a} = key, %{current: cur, attached: set}} ->
        if MapSet.member?(set, sid) or cur == sid do
          new_attached = MapSet.delete(set, sid)

          new_current =
            cond do
              cur != sid -> cur
              MapSet.size(new_attached) == 0 -> nil
              true -> MapSet.to_list(new_attached) |> List.first()
            end

          if new_current == nil and MapSet.size(new_attached) == 0 do
            :ets.delete(@ets_table, key)
          else
            :ets.insert(@ets_table, {key, %{current: new_current, attached: new_attached}})
          end
        end
    end)

    # Drop the in-memory `sessions` entry too (kept in state for the
    # set_current_session/clear-defaults paths that read state.sessions).
    new_state =
      state
      |> update_in([:sessions], &Map.delete(&1, sid))
      |> update_in([:chat_to_session], fn map ->
        map
        |> Enum.reject(fn {_k, v} -> v == sid end)
        |> Enum.into(%{})
      end)

    persist_attached_to_disk()
    {:reply, :ok, new_state}
  end

  def handle_call({:set_default_workspace, c, a, uuid}, _from, state) do
    :ets.insert(@ets_default_workspace, {{c, a}, uuid})
    state = put_in(state, [:chat_to_default_workspace_id, {c, a}], uuid)
    {:reply, :ok, state}
  end

  def handle_call({:clear_default_workspace, c, a}, _from, state) do
    :ets.delete(@ets_default_workspace, {c, a})
    state = update_in(state, [:chat_to_default_workspace_id], &Map.delete(&1, {c, a}))
    {:reply, :ok, state}
  end

  # Persistence helpers — chat_attached.yaml (filename preserved for backwards
  # compat with existing $ESRD_HOME state from the legacy ChatScope.Registry).

  defp persist_path do
    Path.join(Esr.Paths.runtime_home(), "chat_attached.yaml")
  end

  defp load_attached_from_disk do
    path = persist_path()

    case Esr.Session.ChatRouting.FileLoader.load(path) do
      {:ok, entries} ->
        Enum.each(entries, fn %{chat_id: c, app_id: a, sessions: sids, current: cur} ->
          attached = MapSet.new(sids)
          :ets.insert(@ets_table, {{c, a}, %{current: cur, attached: attached}})
        end)

      {:error, reason} ->
        Logger.warning("session_chat_routing: failed to load #{path}: #{inspect(reason)}")
    end

    :ok
  end

  defp persist_attached_to_disk do
    # Only persist when ESRD_HOME is explicitly configured — prevents test runs
    # (which share the default ~/.esrd path) from writing stale state to disk
    # and polluting subsequent test runs via init/1's load_attached_from_disk.
    if System.get_env("ESRD_HOME") do
      entries =
        :ets.tab2list(@ets_table)
        |> Enum.flat_map(fn
          {{c, a}, %{current: cur, attached: set}} ->
            [%{chat_id: c, app_id: a, sessions: MapSet.to_list(set), current: cur}]

          _ ->
            []
        end)

      path = persist_path()

      case Esr.Session.ChatRouting.FileLoader.write(path, entries) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("session_chat_routing: failed to persist #{path}: #{inspect(reason)}")
      end
    else
      :ok
    end
  end
end
