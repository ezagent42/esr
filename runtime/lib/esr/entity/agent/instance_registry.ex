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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp uuid_v4 do
    if Code.ensure_loaded?(Uniq.UUID) do
      Uniq.UUID.uuid4()
    else
      <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
      c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
      d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)
      :io_lib.format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c, d, e]
      )
      |> IO.iodata_to_binary()
    end
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
