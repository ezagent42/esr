defmodule Esr.SessionRegistry do
  @moduledoc """
  YAML-compiled topology registry + runtime mappings.

  Single source of truth for:
  - `agents.yaml` compiled agent definitions
  - `(chat_id, app_id, thread_id) → session_id` lookup (PR-A T1)
  - `(session_id, peer_name) → pid` lookup
  - yaml hot-reload

  See spec §3.3, §3.5, and PR-A multi-app spec §2.1.
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  @reserved_fields ~w(rate_limits timeout_ms allowed_principals)a

  # ETS index for (chat_id, app_id, thread_id) → {session_id, refs}.
  # PR-A T1 extended the key from a 2-tuple to a 3-tuple so two apps
  # with overlapping chat_ids never collide (spec §2.1).
  #
  # Owned by the GenServer; writes route through the owner (handle_call)
  # so consistency with the in-memory `sessions` map is preserved. Reads
  # run directly from the caller process, bypassing the GenServer mailbox.
  # Mirrors the pattern in `Esr.Capabilities.Grants`.
  @ets_table :esr_session_chat_index

  # PR-21g: D8 uniqueness — additional ETS indexes on
  #   {env, username, workspace, name}            → session_id
  #   {env, username, workspace, worktree_branch} → session_id
  # within a single esrd environment ($ESR_INSTANCE), each tuple must
  # be unique. Collisions reject at register-time so two `/new-session`
  # calls competing for the same name (or worktree branch) fail fast
  # rather than silently overwriting tmux sessions / worktree paths.
  @ets_name_index :esr_session_name_index
  @ets_worktree_index :esr_session_worktree_index

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def load_agents(path), do: GenServer.call(__MODULE__, {:load_agents, path})
  def agent_def(name), do: GenServer.call(__MODULE__, {:agent_def, name})

  @doc """
  List all known agent names (PR-21κ — surfaces `/list-agents` data).
  Sorted alphabetically.
  """
  def list_agents, do: GenServer.call(__MODULE__, :list_agents)

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
  spawning tmux — the registry is the source of truth for
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

  PR-A T1: 3-arity (chat_id, app_id, thread_id). The 2-arity wrapper
  was removed deliberately — keys would silently miss for rows that
  didn't have an app_id (write-after-upgrade hazard, spec §2.1).
  """
  def lookup_by_chat_thread(chat_id, app_id, thread_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id, thread_id}) do
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
    # Eagerly load <runtime_home>/agents.yaml at init so agents are
    # available before Admin.Supervisor starts (and its watcher
    # dispatches any pre-queued session_new commands). E2E discovered
    # the race: Application's post-supervisor load_agents_from_disk
    # ran AFTER Supervisor.start_link, allowing the admin_queue
    # watcher to fire `session_new agent=cc` before agents were
    # populated — resulting in `unknown_agent`. Init-time load
    # eliminates the race (this registry is child #8 in the supervisor
    # tree, before Admin.Supervisor at #15).
    #
    # Missing file is fine — callers can still invoke `load_agents/1`
    # to reload or load from an alternate path.
    agents =
      case parse_agents_file(Path.join(Esr.Paths.runtime_home(), "agents.yaml")) do
        {:ok, a} -> a
        _ -> %{}
      end

    {:ok, %{agents: agents, sessions: %{}, chat_to_session: %{}}}
  end

  @impl true
  def handle_call({:load_agents, path}, _from, state) do
    case parse_agents_file(path) do
      {:ok, agents} ->
        {:reply, :ok, %{state | agents: agents}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:agent_def, name}, _from, state) do
    case Map.fetch(state.agents, name) do
      {:ok, def_} -> {:reply, {:ok, def_}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_agents, _from, state) do
    {:reply, state.agents |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call(
        {:register_session, session_id, %{chat_id: c, app_id: a, thread_id: t} = key, refs},
        _from,
        state
      ) do
    # Mirror into the ETS index so `lookup_by_chat_thread/3` can serve
    # direct-reads from the caller process. `:ets.insert/2` on a `:set`
    # table overwrites, matching the re-register semantics of the
    # in-memory state update. PR-A T1: key is the (chat_id, app_id,
    # thread_id) 3-tuple.
    :ets.insert(@ets_table, {{c, a, t}, session_id, refs})

    state =
      state
      |> put_in([:sessions, session_id], %{key: key, refs: refs})
      |> put_in([:chat_to_session, {c, a, t}], session_id)

    {:reply, :ok, state}
  end

  def handle_call({:unregister_session, sid}, _from, state) do
    # PR-21g: clear both indexes' rows for this sid.
    drop_uri_rows_for(sid)

    case Map.get(state.sessions, sid) do
      nil ->
        {:reply, :ok, state}

      %{key: %{chat_id: c, app_id: a, thread_id: t}} ->
        :ets.delete(@ets_table, {c, a, t})

        state =
          state
          |> update_in([:sessions], &Map.delete(&1, sid))
          |> update_in([:chat_to_session], &Map.delete(&1, {c, a, t}))

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
    do: {:reply, {:error, {:invalid_args, "claim_uri requires env/username/workspace/name/worktree_branch"}}, state}

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

  # Internal: yaml parse + reserved-field warning
  defp parse_agents_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      agents = parsed["agents"] || %{}

      agents_compiled =
        for {name, spec} <- agents, into: %{} do
          warn_if_reserved_fields(name, spec)
          {name, compile_agent(spec)}
        end

      {:ok, agents_compiled}
    end
  end

  defp warn_if_reserved_fields(name, spec) do
    for field <- @reserved_fields, Map.has_key?(spec, Atom.to_string(field)) do
      Logger.warning(
        "agents.yaml: agent '#{name}' uses reserved field '#{field}' (not implemented; will be ignored)"
      )
    end
  end

  defp compile_agent(spec) do
    %{
      description: spec["description"] || "",
      capabilities_required: spec["capabilities_required"] || [],
      pipeline: %{
        inbound: spec["pipeline"]["inbound"] || [],
        outbound: spec["pipeline"]["outbound"] || []
      },
      proxies: spec["proxies"] || [],
      params: spec["params"] || []
    }
  end
end
