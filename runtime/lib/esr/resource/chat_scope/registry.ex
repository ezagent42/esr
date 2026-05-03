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

  ## ETS layout

  Three named, protected `:set` tables, owned by this GenServer.
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

  # ETS index for (chat_id, app_id) → {session_id, refs}. PR-21λ
  # collapsed the historic thread_id slot — see moduledoc.
  @ets_table :esr_chat_scope_chat_index

  # PR-21g: D8 uniqueness — additional ETS indexes on
  #   {env, username, workspace, name}            → session_id
  #   {env, username, workspace, worktree_branch} → session_id
  @ets_name_index :esr_chat_scope_name_index
  @ets_worktree_index :esr_chat_scope_worktree_index

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register_session(session_id, chat_thread_key, peer_refs),
    do: GenServer.call(__MODULE__, {:register_session, session_id, chat_thread_key, peer_refs})

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
  Direct ETS lookup — runs in the caller process with no GenServer hop.
  See `@ets_table` docstring above for the read/write split rationale.

  Returns the chat-current session for `(chat_id, app_id)`. PR-21λ
  collapsed the prior 3-tuple `(chat_id, app_id, thread_id)` key —
  see moduledoc.
  """
  def lookup_by_chat(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_k, sid, refs}] -> {:ok, sid, refs}
      [] -> :not_found
    end
  end

  def unregister_session(session_id),
    do: GenServer.call(__MODULE__, {:unregister_session, session_id})

  # GenServer callbacks
  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ets_name_index, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ets_worktree_index, [:named_table, :set, :protected, read_concurrency: true])

    {:ok, %{sessions: %{}, chat_to_session: %{}}}
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

    :ets.insert(@ets_table, {{c, a}, session_id, refs})

    state =
      state
      |> put_in([:sessions, session_id], %{key: key, refs: refs})
      |> put_in([:chat_to_session, {c, a}], session_id)

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
