defmodule Esr.Resource.ChatScope.Registry do
  @moduledoc """
  Chat-scope routing registry — `(chat_id, app_id) → session_id` and the
  D8-uniqueness URI-claim indexes (R5 split from the legacy
  `Esr.SessionRegistry`).

  Two responsibilities, one GenServer:

    1. **Chat-current routing** — exactly one active session per
       `(chat_id, app_id)` slot. `register_session/3` overwrites, leaving
       the prior session as an orphan reachable only by sid (e.g. via
       `/end-session`). PR-21λ collapsed the historic 3-tuple key
       `(chat_id, app_id, thread_id)` because Feishu surfaces a fresh
       thread_id for every top-level message in some chats — keying on
       it caused every "hi" after `/new-session` to miss the slot and
       silently auto-spawn or land on a dead old session.

    2. **URI uniqueness (PR-21g D8)** — within a single esrd environment
       (`$ESR_INSTANCE`), each
         `(env, username, workspace, name)` tuple AND
         `(env, username, workspace, worktree_branch)` tuple
       must be unique. Collisions reject at register-time so two
       `/new-session` calls competing for the same name (or worktree
       branch) fail fast rather than silently overwriting sessions /
       worktree paths.

  See `docs/notes/structural-refactor-plan-r4-r11.md` §四-R5 for the
  motivation: legacy `SessionRegistry` mixed three concerns (agents.yaml,
  chat routing, URI claims). R5 split the agents.yaml concern to
  `Esr.Entity.Agent.Registry`; chat + URI concerns live here.

  ## Phase 2: Multi-session attach/detach state (chat→[sessions])

  The `@ets_table` now stores TWO entry shapes:
    - Old (register_session/3): `{key, sid, refs}` 3-tuple — preserves legacy
      callers that pattern-match `%{feishu_chat_proxy: pid}` from refs.
    - New (attach/detach API): `{key, %{current: sid | nil, attached: MapSet.t()}}`

  New public API:
    - `attach_session/3`    — attach a session UUID; sets as current if first
    - `detach_session/3`    — remove from attached set; promotes next if current
    - `current_session/2`   — return current session UUID or :not_found
    - `attached_sessions/2` — list all attached session UUIDs
    - `reload/0`            — re-read from disk (used in tests + boot)

  `lookup_by_chat/2` handles both ETS shapes as a backward-compat shim.

  Attached state is persisted to `$ESRD_HOME/$ESR_INSTANCE/chat_attached.yaml`
  on every attach/detach when `ESRD_HOME` is explicitly set. This guard prevents
  test runs (which share the default ~/.esrd path) from polluting disk state.

  ## ETS layout

  Four named, protected `:set` tables, owned by this GenServer.
  Reads run directly from the caller process, bypassing the GenServer
  mailbox; writes route through the owner (handle_call) so consistency
  with the in-memory `sessions` map is preserved. Mirrors the pattern in
  `Esr.Resource.Capability.Grants` and the prior SessionRegistry.

  ## R5 §A2 / §B1 note (autonomous decision)

  The R5 spec called for `@behaviour Esr.Interface.LiveRegistry`. The
  match isn't exact: this module exposes
  `register_session/3` (not `register/2`), `unregister_session/1`
  (not `unregister/1`), and several lookup variants that don't fit the
  generic `lookup/1` shape. Forcing the @behaviour today would require
  renaming the public API and breaking every caller (out of R5 scope
  per §N1). Per §B4, a follow-up R-batch can reconcile once the
  `lookup return value normalization` (§四-R4 step 4) sweeps callers.
  **Skipping `@behaviour` for now and documenting here.**
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  # ETS index for (chat_id, app_id) → session entry.
  # Two shapes coexist:
  #   Old (register_session/3): {key, sid, refs}
  #   New (attach/detach API):  {key, %{current: sid | nil, attached: MapSet.t()}}
  @ets_table :esr_chat_scope_chat_index

  # PR-21g: D8 uniqueness — additional ETS indexes on
  #   {env, username, workspace, name}            → session_id
  #   {env, username, workspace, worktree_branch} → session_id
  @ets_name_index :esr_chat_scope_name_index
  @ets_worktree_index :esr_chat_scope_worktree_index

  # T4.8: default workspace index — (chat_id, app_id) → workspace_uuid
  # Future /new-session resolution reads this to pick the default workspace.
  @ets_default_workspace :esr_chat_scope_default_workspace_index

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register_session(session_id, chat_thread_key, peer_refs),
    do: GenServer.call(__MODULE__, {:register_session, session_id, chat_thread_key, peer_refs})

  @doc """
  Phase 2: Attach a session UUID to this `(chat_id, app_id)` scope.

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
  Phase 2: Detach a session UUID from this `(chat_id, app_id)` scope.

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
  Phase 2: Return the current (attached-current) session UUID for this chat.

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
  Phase 2: Return the list of all attached session UUIDs for this chat.

  Direct ETS read — runs in the caller process with no GenServer hop.
  Order of returned list is undefined (MapSet iteration order).
  For legacy entries written by register_session/3, returns [sid].
  """
  @spec attached_sessions(String.t(), String.t()) :: [String.t()]
  def attached_sessions(chat_id, app_id) do
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
  Phase 2: Reload attached state from disk. Clears the `@ets_table` entries
  and repopulates from `chat_attached.yaml`.

  Called when `ESRD_HOME` is set and used in persistence tests.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  PR-21g D8: claim a session URI tuple. Atomically inserts both the
  `name` and the `worktree_branch` key under the
  `(env, username, workspace, …)` namespace, rejecting if either is
  already taken.

  Returns `:ok` on successful claim, or `{:error, {:name_taken, _}}` /
  `{:error, {:worktree_taken, _}}` when a collision is detected.

  Call this BEFORE materialising the worktree on disk and BEFORE
  spawning peers — the registry is the source of truth for
  "this session already exists" outside the disk-state quorum.
  """
  @spec claim_uri(
          String.t(),
          %{
            env: String.t(),
            username: String.t(),
            workspace: String.t(),
            name: String.t(),
            worktree_branch: String.t()
          }
        ) :: :ok | {:error, term()}
  def claim_uri(session_id, %{} = uri_components) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:claim_uri, session_id, uri_components})
  end

  @doc """
  PR-21g: lookup a session by its URI tuple. Used by `/end-session`
  to resolve the user-facing `<name>` to the runtime session_id.
  """
  @spec lookup_by_name(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | :not_found
  def lookup_by_name(env, username, workspace, name)
      when is_binary(env) and is_binary(username) and is_binary(workspace) and is_binary(name) do
    case :ets.lookup(@ets_name_index, {env, username, workspace, name}) do
      [{_k, sid}] -> {:ok, sid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "PR-21g: list every URI-claimed session under a (env, username, workspace) prefix."
  @spec list_uris(String.t(), String.t(), String.t()) :: [{String.t(), String.t()}]
  def list_uris(env, username, workspace) do
    @ets_name_index
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{^env, ^username, ^workspace, name}, sid} -> [{name, sid}]
      _ -> []
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Phase 2 backward-compat shim. Returns the current session in the old
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

  def unregister_session(session_id),
    do: GenServer.call(__MODULE__, {:unregister_session, session_id})

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
    :ets.new(@ets_name_index, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ets_worktree_index, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ets_default_workspace, [:named_table, :set, :protected, read_concurrency: true])

    state = %{sessions: %{}, chat_to_session: %{}, chat_to_default_workspace_id: %{}}

    # Phase 2.4: load persisted attached-set from disk on boot.
    # Guard on ESRD_HOME being explicitly set — prevents test runs sharing
    # the default ~/.esrd path from loading stale state written by prior runs.
    if System.get_env("ESRD_HOME") do
      load_attached_from_disk()
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Clear only the chat-index entries (not URI indexes or default workspace),
    # then reload from disk. Only meaningful when ESRD_HOME is set.
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
          "chat_scope_registry: chat_current slot {#{c}, #{a}} reassigned " <>
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
    # PR-21g: clear both indexes' rows for this sid.
    drop_uri_rows_for(sid)

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

  def handle_call(
        {:claim_uri, sid, %{env: env, username: u, workspace: ws, name: n, worktree_branch: wb}},
        _from,
        state
      )
      when is_binary(env) and is_binary(u) and is_binary(ws) and is_binary(n) and is_binary(wb) do
    name_key = {env, u, ws, n}
    wt_key = {env, u, ws, wb}

    case {:ets.lookup(@ets_name_index, name_key), :ets.lookup(@ets_worktree_index, wt_key)} do
      {[], []} ->
        :ets.insert(@ets_name_index, {name_key, sid})
        :ets.insert(@ets_worktree_index, {wt_key, sid})
        {:reply, :ok, state}

      {[{_, taken_by}], _} ->
        {:reply, {:error, {:name_taken, taken_by}}, state}

      {_, [{_, taken_by}]} ->
        {:reply, {:error, {:worktree_taken, taken_by}}, state}
    end
  end

  def handle_call({:claim_uri, _sid, _bad}, _from, state),
    do:
      {:reply,
       {:error, {:invalid_args, "claim_uri requires env/username/workspace/name/worktree_branch"}},
       state}

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

  # Phase 2.4: persistence helpers

  defp persist_path do
    Path.join(Esr.Paths.runtime_home(), "chat_attached.yaml")
  end

  defp load_attached_from_disk do
    path = persist_path()

    case Esr.Resource.ChatScope.FileLoader.load(path) do
      {:ok, entries} ->
        Enum.each(entries, fn %{chat_id: c, app_id: a, sessions: sids, current: cur} ->
          attached = MapSet.new(sids)
          :ets.insert(@ets_table, {{c, a}, %{current: cur, attached: attached}})
        end)

      {:error, reason} ->
        Logger.warning("chat_scope_registry: failed to load #{path}: #{inspect(reason)}")
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

      case Esr.Resource.ChatScope.FileLoader.write(path, entries) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("chat_scope_registry: failed to persist #{path}: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp drop_uri_rows_for(sid) do
    drop_matching(@ets_name_index, sid)
    drop_matching(@ets_worktree_index, sid)
  end

  defp drop_matching(table, sid) do
    table
    |> :ets.tab2list()
    |> Enum.each(fn
      {key, ^sid} -> :ets.delete(table, key)
      _ -> :ok
    end)
  rescue
    ArgumentError -> :ok
  end
end
