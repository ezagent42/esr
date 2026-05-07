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

  Mutation API (put/1, delete_by_id/1) added in Phase 2 when session
  create/end commands ship.
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
