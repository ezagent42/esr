defmodule Esr.Resource.Session.Registry do
  @moduledoc """
  In-memory registry of all sessions, rebuilt from disk at boot.

  ETS layout:
    * `:esr_resource_sessions_by_uuid` — UUID-keyed: `{uuid, %Struct{}}`.
    * `:esr_resource_session_name_index` — composite-keyed: `{{owner_user_uuid, name}, uuid}`.
      Composite key per spec D6: session names unique within (owner_user, name), not globally.

  Public API (Phase 1 — read-side + reload):
    * `start_link/1`, `reload/0`
    * `get_by_id/1` — returns `{:ok, Struct.t()} | :not_found`
    * `list_all/0` — returns `[Struct.t()]`

  Phase 3 additions (multi-agent per session):
    * `create_session/2` — writes session.json + registers in ETS
    * `get_session/1` — alias for get_by_id/1
    * `add_agent_to_session/5` — write-through to InstanceRegistry + persists to disk
    * `remove_agent_from_session/3` — write-through to InstanceRegistry + persists to disk
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  alias Esr.Paths
  alias Esr.Resource.Session.{Struct, FileLoader}

  @uuid_table :esr_resource_sessions_by_uuid
  @name_index :esr_resource_session_name_index

  ## Public API -----------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @spec get_by_id(String.t()) :: {:ok, Struct.t()} | :not_found
  def get_by_id(uuid) when is_binary(uuid) do
    case :ets.lookup(@uuid_table, uuid) do
      [{^uuid, s}] -> {:ok, s}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @spec list_all() :: [Struct.t()]
  def list_all do
    @uuid_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, s} -> s end)
  rescue
    ArgumentError -> []
  end

  @doc "Alias for get_by_id/1 — returns `{:ok, Struct.t()} | :not_found`."
  @spec get_session(String.t()) :: {:ok, Struct.t()} | :not_found
  def get_session(session_id), do: get_by_id(session_id)

  @doc """
  Create a new session on disk and register it in the ETS tables.

  Writes `<data_dir>/sessions/<uuid>/session.json` using `JsonWriter`.
  A fresh UUID v4 is assigned as the session `id`.

  Returns `{:ok, session_uuid}` on success.
  """
  @spec create_session(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_session(data_dir, attrs) when is_binary(data_dir) and is_map(attrs) do
    GenServer.call(__MODULE__, {:create_session, data_dir, attrs})
  end

  @doc """
  Add an agent instance to the session with `session_id`.

  Delegates name-uniqueness enforcement to `Esr.Entity.Agent.InstanceRegistry`.
  On success, writes the updated agents list back to `session.json`.

  Returns `:ok` or `{:error, {:duplicate_agent_name, name}}`.
  """
  @spec add_agent_to_session(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, {:duplicate_agent_name, String.t()}}
  def add_agent_to_session(data_dir, session_id, type, name, config)
      when is_binary(data_dir) and is_binary(session_id) and is_binary(type) and
             is_binary(name) and is_map(config) do
    GenServer.call(
      __MODULE__,
      {:add_agent_to_session, data_dir, session_id, type, name, config}
    )
  end

  @doc """
  Remove the agent named `name` from the session with `session_id`.

  Returns `:ok`, `{:error, :cannot_remove_primary}`, or `{:error, :not_found}`.
  """
  @spec remove_agent_from_session(String.t(), String.t(), String.t()) ::
          :ok | {:error, :cannot_remove_primary | :not_found}
  def remove_agent_from_session(session_id, name, data_dir)
      when is_binary(session_id) and is_binary(name) and is_binary(data_dir) do
    GenServer.call(__MODULE__, {:remove_agent_from_session, session_id, name, data_dir})
  end

  ## GenServer callbacks ---------------------------------------------------

  @impl GenServer
  def init(_opts) do
    ensure_tables()

    case do_reload() do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("session.registry: boot reload failed (#{inspect(reason)}); starting empty")
        {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    {:reply, do_reload(), state}
  end

  @impl GenServer
  def handle_call({:create_session, data_dir, attrs}, _from, state) do
    uuid = generate_uuid()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    session = %Struct{
      id: uuid,
      name: Map.get(attrs, :name) || Map.get(attrs, "name", ""),
      owner_user: Map.get(attrs, :owner_user) || Map.get(attrs, "owner_user", ""),
      workspace_id: Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id", ""),
      agents: [],
      primary_agent: nil,
      attached_chats: [],
      created_at: now,
      transient: Map.get(attrs, :transient, false)
    }

    session_dir = Path.join([data_dir, "sessions", uuid])
    File.mkdir_p!(session_dir)
    session_json_path = Path.join(session_dir, "session.json")

    case Esr.Resource.Session.JsonWriter.write(session_json_path, session) do
      :ok ->
        :ets.insert(@uuid_table, {uuid, session})
        :ets.insert(@name_index, {{session.owner_user, session.name}, uuid})
        {:reply, {:ok, uuid}, state}

      {:error, reason} ->
        {:reply, {:error, {:write_failed, reason}}, state}
    end
  end

  @impl GenServer
  def handle_call({:add_agent_to_session, data_dir, session_id, type, name, config}, _from, state) do
    case Esr.Entity.Agent.InstanceRegistry.add_instance(%{
           session_id: session_id,
           type: type,
           name: name,
           config: config
         }) do
      :ok ->
        case persist_agents(data_dir, session_id) do
          :ok -> {:reply, :ok, state}
          {:error, _} = err -> {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl GenServer
  def handle_call({:remove_agent_from_session, session_id, name, data_dir}, _from, state) do
    case Esr.Entity.Agent.InstanceRegistry.remove_instance(session_id, name) do
      :ok ->
        case persist_agents(data_dir, session_id) do
          :ok -> {:reply, :ok, state}
          {:error, _} = err -> {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  ## Internals -------------------------------------------------------------

  defp ensure_tables do
    if :ets.info(@uuid_table) == :undefined do
      :ets.new(@uuid_table, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.info(@name_index) == :undefined do
      :ets.new(@name_index, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp do_reload do
    :ets.delete_all_objects(@uuid_table)
    :ets.delete_all_objects(@name_index)

    sessions = scan_sessions_dir()

    Enum.each(sessions, fn s ->
      :ets.insert(@uuid_table, {s.id, s})
      :ets.insert(@name_index, {{s.owner_user, s.name}, s.id})
    end)

    :ok
  end

  defp persist_agents(data_dir, session_id) do
    instances = Esr.Entity.Agent.InstanceRegistry.list(session_id)

    primary =
      case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
        {:ok, n} -> n
        :not_found -> nil
      end

    agents_json =
      Enum.map(instances, fn i -> %{"type" => i.type, "name" => i.name, "config" => i.config} end)

    session_json_path = Path.join([data_dir, "sessions", session_id, "session.json"])

    case File.read(session_json_path) do
      {:ok, raw} ->
        doc =
          raw
          |> Jason.decode!()
          |> Map.put("agents", agents_json)
          |> Map.put("primary_agent", primary)

        tmp_path = session_json_path <> ".tmp"
        File.write!(tmp_path, Jason.encode!(doc, pretty: true))
        File.rename!(tmp_path, session_json_path)

        # Also update ETS with the fresh agents list.
        case :ets.lookup(@uuid_table, session_id) do
          [{^session_id, s}] ->
            agents_atoms =
              Enum.map(instances, fn i -> %{type: i.type, name: i.name, config: i.config} end)

            updated = %{s | agents: agents_atoms, primary_agent: primary}
            :ets.insert(@uuid_table, {session_id, updated})

          [] ->
            :ok
        end

        :ok

      {:error, reason} ->
        {:error, {:session_json_missing, reason}}
    end
  end

  defp generate_uuid, do: UUID.uuid4()

  defp scan_sessions_dir do
    base = Paths.sessions_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn entry ->
        path = Path.join([base, entry, "session.json"])

        case FileLoader.load(path, []) do
          {:ok, s} ->
            [s]

          {:error, :file_missing} ->
            []

          {:error, reason} ->
            Logger.warning("session.registry: skipping #{path} (#{inspect(reason)})")
            []
        end
      end)
    else
      []
    end
  end
end
