defmodule Esr.Entity.Agent.Registry do
  @moduledoc """
  Agent topology registry — agents.yaml cache + hot-reload (R5 split from
  the legacy `Esr.SessionRegistry`).

  Single source of truth for agents.yaml-compiled agent definitions. The
  `Esr.Scope.Router` and admin command modules read from here when
  resolving an agent name to its declared pipeline / capabilities /
  proxies / params shape.

  See `docs/notes/structural-refactor-plan-r4-r11.md` §四-R5 for the
  motivation: legacy `SessionRegistry` mixed three concerns (agents.yaml,
  chat-current routing, URI claims). R5 splits the agents.yaml concern
  here; chat / URI concerns moved to `Esr.Resource.ChatScope.Registry`.

  ## R5 §A2 / §B1 note (autonomous decision)

  The R5 spec called for `@behaviour Esr.Interface.SnapshotRegistry` if
  the API matched closely. The match isn't exact:

    - `agent_def/1` → close to `lookup/1` but `:not_found` vs `:error`
    - `list_agents/0` → close to `list/0` but returns `[name]` not
      `[{key, value}]`
    - `load_agents/1` takes a path and parses the file; the Interface's
      `load_snapshot/1` takes a pre-built map

  Forcing the @behaviour today would either require renaming the public
  API (breaking callers — out of R5 scope per §N1) or adding adapter
  functions just to satisfy the contract (yak-shaving). Per §B4, a
  follow-up R-batch can reconcile the API once `lookup return value
  normalization` (§四-R4 step 4) sweeps callers. **Skipping `@behaviour`
  for now and documenting here.**
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  @reserved_fields ~w(rate_limits timeout_ms allowed_principals)a

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def load_agents(path), do: GenServer.call(__MODULE__, {:load_agents, path})

  @doc """
  Atomically replace the in-memory agents map with `snapshot`. Per
  `Esr.Interface.SnapshotRegistry`. Used by `Esr.Yaml.FragmentMerger`
  to install a composed snapshot built from core defaults + plugin
  fragments + user override.
  """
  @spec load_snapshot(map()) :: :ok
  def load_snapshot(snapshot) when is_map(snapshot) do
    GenServer.call(__MODULE__, {:load_snapshot, snapshot})
  end

  def agent_def(name), do: GenServer.call(__MODULE__, {:agent_def, name})

  @doc """
  List all known agent names (PR-21κ — surfaces `/list-agents` data).
  Sorted alphabetically.
  """
  def list_agents, do: GenServer.call(__MODULE__, :list_agents)

  # GenServer callbacks
  @impl true
  def init(_opts) do
    # Eagerly load <runtime_home>/agents.yaml at init so agents are
    # available before Admin.Supervisor starts (and its watcher
    # dispatches any pre-queued session_new commands). E2E discovered
    # the race: Application's post-supervisor load_agents_from_disk
    # ran AFTER Supervisor.start_link, allowing the admin_queue
    # watcher to fire `session_new agent=cc` before agents were
    # populated — resulting in `unknown_agent`. Init-time load
    # eliminates the race (this registry sits before Admin.Supervisor
    # in the supervisor tree).
    #
    # Missing file is fine — callers can still invoke `load_agents/1`
    # to reload or load from an alternate path.
    agents =
      case parse_agents_file(Path.join(Esr.Paths.runtime_home(), "agents.yaml")) do
        {:ok, a} -> a
        _ -> %{}
      end

    {:ok, %{agents: agents}}
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

  def handle_call({:load_snapshot, snapshot}, _from, state) do
    {:reply, :ok, %{state | agents: snapshot}}
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
