defmodule Esr.Entity.Agent.InstanceRegistry do
  @moduledoc """
  Per-process ETS-backed registry of agent instances within sessions.

  ## Phase 7: multi-session-per-instance

  An instance now belongs to a list of sessions (`session_ids`). The
  same `%Instance{}` record can be looked up via any of its attached
  sessions. Lookup keys live in two ETS tables:

    * `<server_name>` (the metadata table) — `{instance_id, %Instance{}}`
      stores the canonical instance record. This is the source of truth.
    * `<server_name>__nameix` — `{{session_id, name}, instance_id}` is a
      reverse index for O(1) `(session_id, name)` lookup. Each instance
      has one entry here per session it's attached to. Names are unique
      WITHIN each session — an attach to a new session that already
      hosts a different instance under the same name fails loudly.

  Plus auxiliary entries on the metadata table (kept here for cohesion):

    * `{:primary, session_uuid}` → `name` of the session's primary agent.
    * `{:instance_sup, session_uuid, name}` → instance subtree supervisor
      pid (only for instances spawned via `add_instance_and_spawn/2`).

  ## Primary agent

  The first agent added to a session automatically becomes the primary.
  `set_primary/3` changes it. `remove_instance/3` is guarded — the
  primary cannot be removed until another instance becomes primary.

  ## Usage

      {:ok, _} = InstanceRegistry.start_link(name: Esr.Entity.Agent.InstanceRegistry)
  """

  use GenServer
  alias Esr.Entity.Agent.Instance

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Add an agent instance to a session. The `attrs` map must contain at
  minimum: `session_id` (or `session_ids`), `type`, `name`, `config`.

  When `:session_id` is given (singular), it's wrapped to `[session_id]`
  for the new shape.

  Returns `:ok` on success, `{:error, {:duplicate_agent_name, name}}` if
  the name already exists in any of the target sessions.
  """
  @spec add_instance(GenServer.server(), map()) ::
          :ok | {:error, {:duplicate_agent_name, String.t()}}
  def add_instance(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:add_instance, normalize_attrs(attrs)})
  end

  @doc """
  Add an agent instance AND spawn its (CC, PTY) subtree atomically.

  Returns `{:ok, %{cc_pid, pty_pid, actor_ids: %{cc, pty}}}` on success.
  """
  @spec add_instance_and_spawn(GenServer.server(), map()) ::
          {:ok, %{cc_pid: pid(), pty_pid: pid(), actor_ids: map()}}
          | {:error, {:duplicate_agent_name, String.t()} | {:spawn_failed, term()}}
  def add_instance_and_spawn(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:add_instance_and_spawn, normalize_attrs(attrs)}, 30_000)
  end

  @doc """
  Attach an existing instance (resolved via its `(source_session_id, name)`
  primary-key tuple) to an additional session. The instance's
  `session_ids` list grows by one. Idempotent: re-attaching to a session
  already in the list is a no-op.

  Returns:
    * `:ok`
    * `{:error, :not_found}` — instance not found in `source_session_id`
    * `{:error, {:name_taken_in_target, target_session_id}}` — another
      instance with this name already lives in `target_session_id`

  Phase 7 (2026-05-10).
  """
  @spec attach_to_session(GenServer.server(), String.t(), String.t(), String.t()) ::
          :ok
          | {:error, :not_found | {:name_taken_in_target, String.t()}}
  def attach_to_session(server \\ __MODULE__, name, source_session_id, target_session_id)
      when is_binary(name) and is_binary(source_session_id) and is_binary(target_session_id) do
    GenServer.call(server, {:attach_to_session, name, source_session_id, target_session_id})
  end

  @doc """
  Remove the agent named `name` from `session_id`. If the instance has
  more than one session in `session_ids`, the session is detached but
  the instance stays alive (still attached to the remaining sessions).
  If `session_id` is the LAST session, the instance is fully removed.

  Returns `:ok`, `{:error, :cannot_remove_primary}`, or `{:error, :not_found}`.
  """
  @spec remove_instance(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :cannot_remove_primary | :not_found}
  def remove_instance(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    GenServer.call(server, {:remove_instance, session_id, name})
  end

  @doc "Return all instances attached to `session_id` as a list of `%Instance{}`."
  @spec list(GenServer.server(), String.t()) :: [Instance.t()]
  def list(server \\ __MODULE__, session_id) when is_binary(session_id) do
    %{table: tab, name_index: ix} = GenServer.call(server, :tables)

    ix
    |> :ets.match_object({{session_id, :_}, :_})
    |> Enum.map(fn {{_s, _n}, instance_id} ->
      case :ets.lookup(tab, instance_id) do
        [{_, inst}] -> inst
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Fetch a single instance by session + name. Returns `{:ok, inst}` or `:not_found`."
  @spec get(GenServer.server(), String.t(), String.t()) ::
          {:ok, Instance.t()} | :not_found
  def get(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    %{table: tab, name_index: ix} = GenServer.call(server, :tables)

    case :ets.lookup(ix, {session_id, name}) do
      [{_, instance_id}] ->
        case :ets.lookup(tab, instance_id) do
          [{_, inst}] -> {:ok, inst}
          _ -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @doc """
  Set `name` as the primary agent for `session_id`.
  """
  @spec set_primary(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :not_found}
  def set_primary(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    GenServer.call(server, {:set_primary, session_id, name})
  end

  @doc """
  Rename `name` → `new_name` in `session_id`.
  """
  @spec rename_instance(GenServer.server(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :duplicate_agent_name}
  def rename_instance(server \\ __MODULE__, session_id, name, new_name)
      when is_binary(session_id) and is_binary(name) and is_binary(new_name) do
    GenServer.call(server, {:rename_instance, session_id, name, new_name})
  end

  @doc "Return the primary agent name for `session_id`."
  @spec primary(GenServer.server(), String.t()) :: {:ok, String.t()} | :not_found
  def primary(server \\ __MODULE__, session_id) when is_binary(session_id) do
    %{table: tab} = GenServer.call(server, :tables)

    case :ets.lookup(tab, {:primary, session_id}) do
      [{_, name}] when is_binary(name) -> {:ok, name}
      _ -> :not_found
    end
  end

  @doc "Return agent names for session."
  @spec names_for_session(GenServer.server(), String.t()) :: [String.t()]
  def names_for_session(server \\ __MODULE__, session_id) when is_binary(session_id) do
    list(server, session_id) |> Enum.map(& &1.name)
  end

  @doc """
  Look up the PTY actor id for `(session_id, name)`.
  """
  @spec pty_actor_id_for(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | :not_found
  def pty_actor_id_for(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case get(server, session_id, name) do
      {:ok, %Instance{actor_ids: %{pty: pty_id}}} when is_binary(pty_id) -> {:ok, pty_id}
      _ -> :not_found
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    server_name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(server_name, [:set, :public, :named_table])
    name_index = :ets.new(:"#{server_name}__nameix", [:set, :public, :named_table])
    {:ok, %{table: table, name_index: name_index}}
  end

  @impl true
  def handle_call(:tables, _from, state),
    do: {:reply, %{table: state.table, name_index: state.name_index}, state}

  @impl true
  def handle_call({:add_instance, attrs}, _from, state) do
    [primary_sid | _] = session_ids = Map.fetch!(attrs, :session_ids)
    name = Map.fetch!(attrs, :name)

    case Enum.find(session_ids, fn sid -> :ets.lookup(state.name_index, {sid, name}) != [] end) do
      sid when is_binary(sid) ->
        {:reply, {:error, {:duplicate_agent_name, name}}, state}

      nil ->
        instance_id = uuid_v4()

        inst = %Instance{
          id: instance_id,
          session_ids: session_ids,
          type: Map.fetch!(attrs, :type),
          name: name,
          config: Map.get(attrs, :config, %{}),
          created_at: iso_now()
        }

        :ets.insert(state.table, {instance_id, inst})

        for sid <- session_ids do
          :ets.insert(state.name_index, {{sid, name}, instance_id})
        end

        # Auto-promote to primary in the originating session if first agent.
        if :ets.lookup(state.table, {:primary, primary_sid}) == [] do
          :ets.insert(state.table, {{:primary, primary_sid}, name})
        end

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:remove_instance, session_id, name}, _from, state) do
    case :ets.lookup(state.name_index, {session_id, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{_, instance_id}] ->
        case primary_for(state, session_id) do
          ^name ->
            {:reply, {:error, :cannot_remove_primary}, state}

          _ ->
            do_detach(state, instance_id, session_id, name)
            {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:set_primary, session_id, name}, _from, state) do
    case :ets.lookup(state.name_index, {session_id, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [_] ->
        :ets.insert(state.table, {{:primary, session_id}, name})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:rename_instance, sid, name, new_name}, _from, state) do
    cond do
      name == new_name ->
        {:reply, :ok, state}

      :ets.lookup(state.name_index, {sid, new_name}) != [] ->
        {:reply, {:error, :duplicate_agent_name}, state}

      true ->
        case :ets.lookup(state.name_index, {sid, name}) do
          [{_, instance_id}] ->
            case :ets.lookup(state.table, instance_id) do
              [{_, %Instance{} = inst}] ->
                new_inst = %{inst | name: new_name}
                :ets.insert(state.table, {instance_id, new_inst})

                # Move every session-keyed name index entry that belongs
                # to this instance (rename is global since names must
                # match across the instance's session_ids).
                for s <- inst.session_ids do
                  :ets.delete(state.name_index, {s, name})
                  :ets.insert(state.name_index, {{s, new_name}, instance_id})
                end

                # Mirror primary pointer for any session where this was
                # the primary.
                for s <- inst.session_ids do
                  case :ets.lookup(state.table, {:primary, s}) do
                    [{_, ^name}] ->
                      :ets.insert(state.table, {{:primary, s}, new_name})

                    _ ->
                      :ok
                  end
                end

                # Mirror agent_sup_via key if it exists.
                for s <- inst.session_ids do
                  case :ets.lookup(state.table, {:instance_sup, s, name}) do
                    [{_, sup_pid}] ->
                      :ets.delete(state.table, {:instance_sup, s, name})
                      :ets.insert(state.table, {{:instance_sup, s, new_name}, sup_pid})

                    _ ->
                      :ok
                  end
                end

                {:reply, :ok, state}

              [] ->
                {:reply, {:error, :not_found}, state}
            end

          [] ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:attach_to_session, name, source_sid, target_sid}, _from, state) do
    case :ets.lookup(state.name_index, {source_sid, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{_, instance_id}] ->
        case :ets.lookup(state.table, instance_id) do
          [{_, %Instance{} = inst}] ->
            cond do
              target_sid in inst.session_ids ->
                # Idempotent: already attached.
                {:reply, :ok, state}

              :ets.lookup(state.name_index, {target_sid, name}) != [] ->
                {:reply, {:error, {:name_taken_in_target, target_sid}}, state}

              true ->
                new_inst = %{inst | session_ids: inst.session_ids ++ [target_sid]}
                :ets.insert(state.table, {instance_id, new_inst})
                :ets.insert(state.name_index, {{target_sid, name}, instance_id})
                {:reply, :ok, state}
            end

          [] ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:add_instance_and_spawn, attrs}, _from, state) do
    [primary_sid | _] = session_ids = Map.fetch!(attrs, :session_ids)
    name = Map.fetch!(attrs, :name)
    type = Map.fetch!(attrs, :type)
    config = Map.get(attrs, :config, %{})

    case Enum.find(session_ids, fn sid -> :ets.lookup(state.name_index, {sid, name}) != [] end) do
      sid when is_binary(sid) ->
        {:reply, {:error, {:duplicate_agent_name, name}}, state}

      nil ->
        cc_actor_id = uuid_v4()
        pty_actor_id = uuid_v4()

        cc_args = build_cc_args(primary_sid, name, cc_actor_id, pty_actor_id, type, config)
        pty_args = build_pty_args(primary_sid, name, pty_actor_id, config)

        agent_sup_via =
          {:via, Registry, {Esr.Session.Registry, {:agent_sup, primary_sid}}}

        spawn_result =
          try do
            Esr.Session.AgentSupervisor.add_agent_subtree(agent_sup_via, %{
              session_id: primary_sid,
              name: name,
              cc_args: cc_args,
              pty_args: pty_args
            })
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        case spawn_result do
          {:ok, instance_sup_pid} ->
            cc_pid = resolve_child_pid(instance_sup_pid, Esr.Entity.CCProcess)
            pty_pid = resolve_child_pid(instance_sup_pid, Esr.Entity.PtyProcess)

            inst = %Instance{
              id: cc_actor_id,
              session_ids: session_ids,
              type: type,
              name: name,
              config: config,
              created_at: iso_now(),
              actor_ids: %{cc: cc_actor_id, pty: pty_actor_id}
            }

            :ets.insert(state.table, {cc_actor_id, inst})

            for sid <- session_ids do
              :ets.insert(state.name_index, {{sid, name}, cc_actor_id})
            end

            # instance_sup is keyed off the spawn-time session (primary).
            :ets.insert(state.table, {{:instance_sup, primary_sid, name}, instance_sup_pid})

            if :ets.lookup(state.table, {:primary, primary_sid}) == [] do
              :ets.insert(state.table, {{:primary, primary_sid}, name})
            end

            {:reply,
             {:ok,
              %{
                cc_pid: cc_pid,
                pty_pid: pty_pid,
                actor_ids: %{cc: cc_actor_id, pty: pty_actor_id}
              }}, state}

          {:error, reason} ->
            cleanup_index_placeholder(primary_sid, name)
            {:reply, {:error, {:spawn_failed, reason}}, state}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_attrs(attrs) do
    cond do
      Map.has_key?(attrs, :session_ids) ->
        attrs

      Map.has_key?(attrs, :session_id) ->
        sid = Map.fetch!(attrs, :session_id)
        attrs |> Map.put(:session_ids, [sid]) |> Map.delete(:session_id)

      true ->
        attrs
    end
  end

  defp primary_for(state, session_id) do
    case :ets.lookup(state.table, {:primary, session_id}) do
      [{_, n}] -> n
      _ -> nil
    end
  end

  # Detach `session_id` from the instance. If the instance has more
  # sessions in its list, leave the metadata row alive (stripped of
  # this session). If this was the last session, delete the instance
  # row outright.
  defp do_detach(state, instance_id, session_id, name) do
    :ets.delete(state.name_index, {session_id, name})

    case :ets.lookup(state.table, instance_id) do
      [{_, %Instance{} = inst}] ->
        new_session_ids = inst.session_ids -- [session_id]

        if new_session_ids == [] do
          :ets.delete(state.table, instance_id)
        else
          :ets.insert(state.table, {instance_id, %{inst | session_ids: new_session_ids}})
        end

      _ ->
        :ok
    end

    :ok
  end

  defp uuid_v4, do: UUID.uuid4()

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp build_cc_args(session_id, name, actor_id, pty_actor_id, type, config) do
    %{
      session_id: session_id,
      name: name,
      actor_id: actor_id,
      pty_actor_id: pty_actor_id,
      handler_module: resolve_handler_module(type, config),
      proxy_ctx: %{session_id: session_id}
    }
  end

  defp build_pty_args(session_id, name, actor_id, config) do
    base = %{
      session_name: name,
      dir: resolve_workspace_dir(session_id, config),
      session_id: session_id,
      name: name,
      actor_id: actor_id
    }

    case Map.get(config, "start_cmd") || Map.get(config, :start_cmd) do
      cmd when is_binary(cmd) and cmd != "" -> Map.put(base, :start_cmd, cmd)
      _ -> base
    end
  end

  defp resolve_child_pid(instance_sup_pid, child_module) do
    instance_sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_module, pid, :worker, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp resolve_handler_module(_type, _config), do: "cc_adapter_runner"

  defp resolve_workspace_dir(session_id, config) do
    case Map.get(config, "dir") || Map.get(config, :dir) do
      d when is_binary(d) and d != "" -> d
      _ -> "/tmp/esr-agent-#{session_id}"
    end
  end

  defp cleanup_index_placeholder(session_id, name) do
    try do
      :ets.delete(:esr_actor_name_index, {session_id, name})
    catch
      _, _ -> :ok
    end

    :ok
  end
end
