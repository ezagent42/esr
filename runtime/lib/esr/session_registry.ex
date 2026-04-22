defmodule Esr.SessionRegistry do
  @moduledoc """
  YAML-compiled topology registry + runtime mappings.

  Single source of truth for:
  - `agents.yaml` compiled agent definitions
  - `(chat_id, thread_id) → session_id` lookup
  - `(session_id, peer_name) → pid` lookup
  - yaml hot-reload

  See spec §3.3 and §3.5.
  """
  use GenServer
  require Logger

  @reserved_fields ~w(rate_limits timeout_ms allowed_principals)a

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def load_agents(path), do: GenServer.call(__MODULE__, {:load_agents, path})
  def agent_def(name), do: GenServer.call(__MODULE__, {:agent_def, name})

  def register_session(session_id, chat_thread_key, peer_refs),
    do: GenServer.call(__MODULE__, {:register_session, session_id, chat_thread_key, peer_refs})

  def lookup_by_chat_thread(chat_id, thread_id),
    do: GenServer.call(__MODULE__, {:lookup_by_chat_thread, chat_id, thread_id})

  def unregister_session(session_id),
    do: GenServer.call(__MODULE__, {:unregister_session, session_id})

  # GenServer callbacks
  @impl true
  def init(_opts) do
    {:ok, %{agents: %{}, sessions: %{}, chat_to_session: %{}}}
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

  def handle_call(
        {:register_session, session_id, %{chat_id: c, thread_id: t} = key, refs},
        _from,
        state
      ) do
    state =
      state
      |> put_in([:sessions, session_id], %{key: key, refs: refs})
      |> put_in([:chat_to_session, {c, t}], session_id)

    {:reply, :ok, state}
  end

  def handle_call({:lookup_by_chat_thread, c, t}, _from, state) do
    case Map.get(state.chat_to_session, {c, t}) do
      nil ->
        {:reply, :not_found, state}

      sid ->
        refs = get_in(state, [:sessions, sid, :refs]) || %{}
        {:reply, {:ok, sid, refs}, state}
    end
  end

  def handle_call({:unregister_session, sid}, _from, state) do
    case Map.get(state.sessions, sid) do
      nil ->
        {:reply, :ok, state}

      %{key: %{chat_id: c, thread_id: t}} ->
        state =
          state
          |> update_in([:sessions], &Map.delete(&1, sid))
          |> update_in([:chat_to_session], &Map.delete(&1, {c, t}))

        {:reply, :ok, state}
    end
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
