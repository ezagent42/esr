defmodule Esr.Entity.Agent.StatefulRegistry do
  @moduledoc """
  Phase 3 PR-3.2: registry of "stateful" Entity modules — peers that
  `Esr.Session.AgentSpawner` actually spawns per-session (vs stateless
  Proxy modules that are recorded as `{:proxy_module, Mod}` markers).

  Pre-PR-3.2 this lived as a hardcoded `@stateful_impls` MapSet at
  compile-time inside AgentSpawner, with feishu + cc_mcp peers in core.
  Per the plugin migration spec: those modules MOVE to plugin dirs in
  PR-3.3 / PR-3.6, and core can no longer reference them by alias. The
  registry decouples the spawner from concrete plugin module names.

  ## Population

  Two sources:

  1. **Core-shipped Stateful peers** — registered at boot by
     `Esr.Application.start/2` before plugin Loader runs. Today the
     only genuinely-core stateful peer is `Esr.Entity.PtyProcess`
     (used by both feishu and claude_code pipelines).

  2. **Plugin manifests** — `entities:` entries with `kind: "stateful"`
     are registered by `Esr.Plugin.Loader.register_entities/1` when
     each plugin starts. feishu plugin contributes FeishuChatProxy +
     FeishuAppAdapter; claude_code plugin contributes CCProcess.

  ## Public read API (ETS-direct, no GenServer hop)

      Esr.Entity.Agent.StatefulRegistry.stateful?(Esr.Entity.CCProcess)
      #=> true

  ## Why a separate ETS table

  Lookups happen on every session_new spawn (per-peer in the inbound
  pipeline). Going through the GenServer would serialize every spawn
  through one process; ETS reads are concurrent and lock-free.
  """

  use GenServer

  @table :esr_stateful_registry

  ## Public API

  @doc "Start the registry. Registered globally as `__MODULE__`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Register `module` as a stateful Entity. Idempotent. Returns `:ok`.
  Synchronous — writes are visible to subsequent `stateful?/1` calls.
  """
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc "Remove a registration. Idempotent."
  @spec unregister(module()) :: :ok
  def unregister(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:unregister, module})
  end

  @doc "Returns true if `module` is registered."
  @spec stateful?(module()) :: boolean()
  def stateful?(module) when is_atom(module) do
    case :ets.lookup(@table, module) do
      [{^module, _}] -> true
      [] -> false
    end
  end

  @doc "Return the full registered set (sorted by module name)."
  @spec list() :: [module()]
  def list do
    :ets.tab2list(@table) |> Enum.map(fn {mod, _} -> mod end) |> Enum.sort()
  end

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    :ets.insert(@table, {module, true})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, module}, _from, state) do
    :ets.delete(@table, module)
    {:reply, :ok, state}
  end
end
