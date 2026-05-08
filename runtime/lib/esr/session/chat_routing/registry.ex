defmodule Esr.Session.ChatRouting.Registry do
  @moduledoc """
  Chat-scope routing registry — `(chat_id, app_id) → session_id`.

  Split from `Esr.Resource.ChatScope.Registry` (R5) per the cleanup-PR spec
  rev-3 §0: chat-routing concerns live here; URI-uniqueness concerns live
  in `Esr.Session.NameIndex.Registry`.

  ## Responsibilities

  Exactly one active session per `(chat_id, app_id)` slot.
  `register_session/3` overwrites, leaving the prior session as an orphan
  reachable only by sid (e.g. via `/end-session`). PR-21λ collapsed the
  historic 3-tuple key `(chat_id, app_id, thread_id)` because Feishu surfaces
  a fresh thread_id for every top-level message in some chats — keying on it
  caused every "hi" after `/new-session` to miss the slot and silently
  auto-spawn or land on a dead old session.

  ## Multi-session attach/detach state (chat→[sessions])

  The `@ets_table` stores TWO entry shapes:
    - Old (register_session/3): `{key, sid, refs}` 3-tuple — preserves legacy
      callers that pattern-match `%{feishu_chat_proxy: pid}` from refs.
    - New (attach/detach API): `{key, %{current: sid | nil, attached: MapSet.t()}}`

  Public API:
    - `register_session/3`    — legacy chat-current overwrite (writes 3-tuple)
    - `attach_session/3`      — attach a session UUID; sets as current if first
    - `detach_session/3`      — remove from attached set; promotes next if current
    - `current_session/2`     — return current session UUID or :not_found
    - `list_sessions/2`       — list all attached session UUIDs
    - `lookup_by_chat/2`      — backward-compat shim returns {:ok, sid, refs}
    - `unregister_session/1`  — drop chat slot for sid (orphan-safe)
    - `set_default_workspace/3` / `get_default_workspace/2` / `clear_default_workspace/2`
    - `reload/0`              — re-read from disk (used in tests + boot)

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

  # ETS index for (chat_id, app_id) → session entry.
  # Two shapes coexist (see moduledoc for legacy vs new).
  @ets_table :esr_session_chat_routing

  # T4.8: default workspace index — (chat_id, app_id) → workspace_uuid.
  @ets_default_workspace :esr_session_chat_routing_default_workspace

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register_session(session_id, chat_thread_key, peer_refs),
    do: GenServer.call(__MODULE__, {:register_session, session_id, chat_thread_key, peer_refs})

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
  Also handles legacy entries written by `register_session/3`.
  """
  @spec current_session(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def current_session(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{current: nil}}] -> :not_found
      [{_, %{current: sid}}] when is_binary(sid) -> {:ok, sid}
      # Legacy format written by register_session/3
      [{_k, sid, _refs}] when is_binary(sid) -> {:ok, sid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Return the list of all attached session UUIDs for this chat.

  Direct ETS read — runs in the caller process with no GenServer hop.
  Order of returned list is undefined (MapSet iteration order).
  For legacy entries written by register_session/3, returns [sid].
  """
  @spec list_sessions(String.t(), String.t()) :: [String.t()]
  def list_sessions(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{attached: set}}] -> MapSet.to_list(set)
      # Legacy format written by register_session/3
      [{_k, sid, _refs}] when is_binary(sid) -> [sid]
      [] -> []
    end
  rescue
    ArgumentError -> []
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

  @doc """
  Backward-compat shim. Returns the current session in the old
  `{:ok, sid, refs}` format so existing callers don't break.

  Handles both ETS shapes:
    - New shape (attach/detach): returns `{:ok, current_sid, %{}}`
    - Old shape (register_session/3): returns `{:ok, sid, refs}` with original refs

  Direct ETS lookup — runs in the caller process with no GenServer hop.
  """
  def lookup_by_chat(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{current: nil}}] -> :not_found
      [{_, %{current: sid}}] when is_binary(sid) -> {:ok, sid, %{}}
      # Old format written by register_session/3 — preserve original refs
      [{_k, sid, refs}] when is_binary(sid) -> {:ok, sid, refs}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  def unregister_session(session_id) do
    result = GenServer.call(__MODULE__, {:unregister_session, session_id})
    # Mirrors the legacy ChatScope.Registry contract: a single
    # unregister_session call clears BOTH the chat slot AND the URI claims.
    # Callers expect this conjoined cleanup; tolerate NameIndex not running.
    _ = safe_release(session_id)
    result
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
  def handle_call(
        {:register_session, session_id, %{chat_id: c, app_id: a} = key, refs},
        _from,
        state
      ) do
    # PR-21λ: chat-current overwrite. `:ets.insert/2` on a `:set` table
    # already replaces by key; we additionally log when the previous
    # occupant was a different sid so operators can correlate orphaned
    # sessions back to the slash that displaced them.
    case Map.get(state.chat_to_session, {c, a}) do
      nil ->
        :ok

      ^session_id ->
        :ok

      prev_sid ->
        Logger.info(
          "session_chat_routing: chat_current slot {#{c}, #{a}} reassigned " <>
            "#{prev_sid} → #{session_id} (prior session is now an orphan)"
        )
    end

    # Write old-format 3-tuple so callers that pattern-match
    # %{feishu_chat_proxy: pid} from refs keep working (lookup_by_chat handles both).
    :ets.insert(@ets_table, {{c, a}, session_id, refs})

    state =
      state
      |> put_in([:sessions, session_id], %{key: key, refs: refs})
      |> put_in([:chat_to_session, {c, a}], session_id)

    {:reply, :ok, state}
  end

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

  def handle_call({:unregister_session, sid}, _from, state) do
    case Map.get(state.sessions, sid) do
      nil ->
        {:reply, :ok, state}

      %{key: %{chat_id: c, app_id: a}} ->
        # PR-21λ: only clear the chat slot if it still belongs to this
        # sid. An orphan session (displaced by a later `/new-session`)
        # tearing down later must not kick the chat-current session
        # that overwrote it.
        if Map.get(state.chat_to_session, {c, a}) == sid do
          :ets.delete(@ets_table, {c, a})
        end

        state =
          state
          |> update_in([:sessions], &Map.delete(&1, sid))
          |> update_in([:chat_to_session], fn map ->
            if Map.get(map, {c, a}) == sid, do: Map.delete(map, {c, a}), else: map
          end)

        {:reply, :ok, state}
    end
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
