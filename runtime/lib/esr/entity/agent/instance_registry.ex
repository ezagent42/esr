defmodule Esr.Entity.Agent.InstanceRegistry do
  @moduledoc """
  Per-process ETS-backed registry of agent instances within sessions.

  ## ETS layout

  Single table: `{session_uuid, agent_name} => %Instance{}` for O(1)
  name-uniqueness checks and O(1) per-agent lookup.

  A separate `{:primary, session_uuid} => agent_name` entry tracks the
  primary agent for each session.

  ## Name uniqueness

  Names are unique within a session across all agent types (spec Q7=B).
  `add_instance/2` rejects a second instance with the same name in the
  same session regardless of type.

  ## Primary agent

  The first agent added to a session automatically becomes the primary
  (spec §4.B `/session:new` → "Primary = first agent added").
  `set_primary/3` changes it at any time. `remove_instance/3` is
  guarded: the primary agent cannot be removed until another is made
  primary first.

  ## Usage

  Start as a named GenServer (tests pass an atom as `name:`; production
  code starts a single global instance named `__MODULE__`):

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
  Add an agent instance to `session_id`. The `attrs` map must contain at
  minimum: `session_id`, `type`, `name`, `config`.

  Returns `:ok` on success, `{:error, {:duplicate_agent_name, name}}` if the
  name already exists in the session.
  """
  @spec add_instance(GenServer.server(), map()) ::
          :ok | {:error, {:duplicate_agent_name, String.t()}}
  def add_instance(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:add_instance, attrs})
  end

  @doc """
  Add an agent instance AND spawn its (CC, PTY) subtree atomically.

  Serialized via the GenServer mailbox — no two concurrent calls for
  the same `{session_id, name}` can both pass the uniqueness check.

  Steps:
    1. Look up `{session_id, name}` in the metadata table; reject
       if already present (`:duplicate_agent_name`).
    2. Resolve the per-session `Esr.Scope.AgentSupervisor` via
       `{:via, Registry, {Esr.Scope.Registry, {:agent_sup, sid}}}`
       and call `add_agent_subtree/2`.
    3. On success: write the `%Instance{}` ETS record, plus
       `{:instance_sup, sid, name, instance_sup_pid}` so
       remove_instance can cascade-terminate the subtree.
    4. On spawn failure: clean the Index 2 name placeholder
       (`:esr_actor_name_index`) so a retry isn't blocked.

  Returns:
    - `{:ok, %{cc_pid, pty_pid, actor_ids: %{cc, pty}}}` on success.
    - `{:error, {:duplicate_agent_name, name}}` if name is taken.
    - `{:error, {:spawn_failed, reason}}` if the AgentSupervisor refuses.
  """
  @spec add_instance_and_spawn(GenServer.server(), map()) ::
          {:ok, %{cc_pid: pid(), pty_pid: pid(), actor_ids: map()}}
          | {:error, {:duplicate_agent_name, String.t()} | {:spawn_failed, term()}}
  def add_instance_and_spawn(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:add_instance_and_spawn, attrs}, 30_000)
  end

  @doc """
  Remove the agent named `name` from `session_id`.

  Returns `:ok`, `{:error, :cannot_remove_primary}`, or `{:error, :not_found}`.
  """
  @spec remove_instance(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :cannot_remove_primary | :not_found}
  def remove_instance(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    GenServer.call(server, {:remove_instance, session_id, name})
  end

  @doc "Return all instances for `session_id` as a list of `%Instance{}`."
  @spec list(GenServer.server(), String.t()) :: [Instance.t()]
  def list(server \\ __MODULE__, session_id) when is_binary(session_id) do
    tab = GenServer.call(server, :table_name)

    :ets.match_object(tab, {{session_id, :_}, :_})
    |> Enum.filter(fn {{_s, k}, _} -> k != :__primary__ end)
    |> Enum.map(fn {_key, inst} -> inst end)
  end

  @doc "Fetch a single instance by session + name. Returns `{:ok, inst}` or `:not_found`."
  @spec get(GenServer.server(), String.t(), String.t()) ::
          {:ok, Instance.t()} | :not_found
  def get(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    tab = GenServer.call(server, :table_name)
    case :ets.lookup(tab, {session_id, name}) do
      [{_, inst}] -> {:ok, inst}
      [] -> :not_found
    end
  end

  @doc """
  Set `name` as the primary agent for `session_id`.

  Returns `:ok` or `{:error, :not_found}` if the name doesn't exist.
  """
  @spec set_primary(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :not_found}
  def set_primary(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    GenServer.call(server, {:set_primary, session_id, name})
  end

  @doc """
  Return the primary agent name for `session_id`.

  Returns `{:ok, name}` or `:not_found`.
  """
  @spec primary(GenServer.server(), String.t()) :: {:ok, String.t()} | :not_found
  def primary(server \\ __MODULE__, session_id) when is_binary(session_id) do
    tab = GenServer.call(server, :table_name)
    case :ets.lookup(tab, {session_id, :__primary__}) do
      [{_, name}] when is_binary(name) -> {:ok, name}
      _ -> :not_found
    end
  end

  @doc "Return agent names for session (used by name-uniqueness check in AddAgent)."
  @spec names_for_session(GenServer.server(), String.t()) :: [String.t()]
  def names_for_session(server \\ __MODULE__, session_id) when is_binary(session_id) do
    list(server, session_id) |> Enum.map(& &1.name)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Each named process owns its own ETS table (named by the server name so
    # tests using unique atom names don't collide).
    server_name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(server_name, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:table_name, _from, state), do: {:reply, state.table, state}

  @impl true
  def handle_call({:add_instance, attrs}, _from, state) do
    session_id = Map.fetch!(attrs, :session_id)
    name = Map.fetch!(attrs, :name)

    case :ets.lookup(state.table, {session_id, name}) do
      [_] ->
        {:reply, {:error, {:duplicate_agent_name, name}}, state}

      [] ->
        inst = %Instance{
          id: uuid_v4(),
          session_id: session_id,
          type: Map.fetch!(attrs, :type),
          name: name,
          config: Map.get(attrs, :config, %{}),
          created_at: iso_now()
        }

        :ets.insert(state.table, {{session_id, name}, inst})

        # Auto-promote to primary if this is the first agent in the session.
        if :ets.lookup(state.table, {session_id, :__primary__}) == [] do
          :ets.insert(state.table, {{session_id, :__primary__}, name})
        end

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:remove_instance, session_id, name}, _from, state) do
    case :ets.lookup(state.table, {session_id, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [_] ->
        primary_name =
          case :ets.lookup(state.table, {session_id, :__primary__}) do
            [{_, n}] -> n
            _ -> nil
          end

        if primary_name == name do
          {:reply, {:error, :cannot_remove_primary}, state}
        else
          :ets.delete(state.table, {session_id, name})
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:set_primary, session_id, name}, _from, state) do
    case :ets.lookup(state.table, {session_id, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [_] ->
        :ets.insert(state.table, {{session_id, :__primary__}, name})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:add_instance_and_spawn, attrs}, _from, state) do
    session_id = Map.fetch!(attrs, :session_id)
    name = Map.fetch!(attrs, :name)
    type = Map.fetch!(attrs, :type)
    config = Map.get(attrs, :config, %{})

    case :ets.lookup(state.table, {session_id, name}) do
      [_] ->
        {:reply, {:error, {:duplicate_agent_name, name}}, state}

      [] ->
        cc_actor_id = uuid_v4()
        pty_actor_id = uuid_v4()

        cc_args = build_cc_args(session_id, name, cc_actor_id, type, config)
        pty_args = build_pty_args(session_id, name, pty_actor_id, config)

        agent_sup_via =
          {:via, Registry, {Esr.Scope.Registry, {:agent_sup, session_id}}}

        spawn_result =
          try do
            Esr.Scope.AgentSupervisor.add_agent_subtree(agent_sup_via, %{
              session_id: session_id,
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
              session_id: session_id,
              type: type,
              name: name,
              config: config,
              created_at: iso_now()
            }

            :ets.insert(state.table, {{session_id, name}, inst})
            :ets.insert(state.table, {{:instance_sup, session_id, name}, instance_sup_pid})

            if :ets.lookup(state.table, {session_id, :__primary__}) == [] do
              :ets.insert(state.table, {{session_id, :__primary__}, name})
            end

            {:reply,
             {:ok,
              %{
                cc_pid: cc_pid,
                pty_pid: pty_pid,
                actor_ids: %{cc: cc_actor_id, pty: pty_actor_id}
              }}, state}

          {:error, reason} ->
            cleanup_index_placeholder(session_id, name)
            {:reply, {:error, {:spawn_failed, reason}}, state}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp uuid_v4, do: UUID.uuid4()

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp build_cc_args(session_id, name, actor_id, type, config) do
    %{
      session_id: session_id,
      name: name,
      actor_id: actor_id,
      handler_module: resolve_handler_module(type, config),
      proxy_ctx: %{session_id: session_id}
    }
  end

  defp build_pty_args(session_id, name, actor_id, config) do
    %{
      session_name: name,
      dir: resolve_workspace_dir(session_id, config),
      session_id: session_id,
      name: name,
      actor_id: actor_id
    }
  end

  defp resolve_child_pid(instance_sup_pid, child_module) do
    instance_sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_module, pid, :worker, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  # Default to "cc_adapter_runner" handler — same fallback Esr.Entity.CCProcess's
  # spawn_args/1 uses. Future: per-type lookup from agent type registry.
  defp resolve_handler_module(_type, _config), do: "cc_adapter_runner"

  defp resolve_workspace_dir(session_id, config) do
    case Map.get(config, "dir") || Map.get(config, :dir) do
      d when is_binary(d) and d != "" -> d
      _ -> "/tmp/esr-agent-#{session_id}"
    end
  end

  # Best-effort cleanup if a peer registered itself in Index 2/3 before
  # spawn failed elsewhere in the subtree. The IndexWatcher monitors
  # processes too, so DOWN events also clean — this is just to close
  # the race window when start_child returns an error.
  defp cleanup_index_placeholder(session_id, name) do
    try do
      :ets.delete(:esr_actor_name_index, {session_id, name})
    catch
      _, _ -> :ok
    end

    :ok
  end
end
