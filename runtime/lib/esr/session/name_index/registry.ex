defmodule Esr.Session.NameIndex.Registry do
  @moduledoc """
  Session URI uniqueness registry — D8 name + worktree-branch indexes.

  Split from `Esr.Resource.ChatScope.Registry` (R5) per the cleanup-PR spec
  rev-3 §0: chat-routing concerns live in `Esr.Session.ChatRouting.Registry`;
  URI-uniqueness concerns live here.

  ## Responsibilities

  Within a single esrd environment (`$ESR_INSTANCE`), each
    `(env, username, workspace, name)` tuple AND
    `(env, username, workspace, worktree_branch)` tuple
  must be unique. Collisions reject at register-time so two `/new-session`
  calls competing for the same name (or worktree branch) fail fast rather
  than silently overwriting sessions / worktree paths.

  Public API:
    - `claim_uri/2`        — atomically claim both (name, worktree_branch) keys
    - `lookup_by_name/4`   — `(env, username, workspace, name) → sid`
    - `list_uris/3`        — list all `{name, sid}` under a `(env, username, workspace)` prefix
    - `release_uri/1`      — drop both indexes' rows for a session_id

  This module mirrors `Esr.Resource.Workspace.NameIndex`'s shape
  (ETS-backed, read-mostly) but operates on the session URI tuple.
  Note: this is for SESSION URI uniqueness, not user/workspace name lookup —
  see `Esr.Entity.User.NameIndex` and `Esr.Resource.Workspace.NameIndex`
  for those.

  ## ETS layout

  Two named, protected `:set` tables, owned by this GenServer.
  Reads run directly from the caller process; writes route through the
  owner so collision-detection is atomic.

  ## Persistence

  No on-disk persistence — the indexes are rebuilt from session.json scans
  on boot via `Esr.Resource.SessionMetadata.scan_active_uris/0` (or
  equivalent caller-driven re-claim during boot).
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  # D8 uniqueness — ETS indexes on
  #   {env, username, workspace, name}            → session_id
  #   {env, username, workspace, worktree_branch} → session_id
  @ets_name_index :esr_session_name_index
  @ets_worktree_index :esr_session_name_index_worktree

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Claim a session URI tuple. Atomically inserts both the
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
  Lookup a session by its URI tuple. Used by `/end-session` to resolve
  the user-facing `<name>` to the runtime session_id.
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

  @doc "List every URI-claimed session under a (env, username, workspace) prefix."
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
  Release both indexes' rows for a session_id. Idempotent.
  Called when a session is unregistered / ended.
  """
  @spec release_uri(String.t()) :: :ok
  def release_uri(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:release_uri, session_id})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@ets_name_index, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ets_worktree_index, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
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

  def handle_call({:release_uri, sid}, _from, state) do
    drop_matching(@ets_name_index, sid)
    drop_matching(@ets_worktree_index, sid)
    {:reply, :ok, state}
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
