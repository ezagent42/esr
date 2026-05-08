defmodule Esr.Resource.Media.PluginRegistry do
  @moduledoc """
  ETS-backed registry of plugin media_types capabilities.

  Populated by `Esr.Plugin.Loader` at boot/reload from each
  manifest.yaml's `declares.media_types` block (opt-in per spec D5).
  Routing layer (e.g. `Esr.Resource.Media.Inbound.handle/2` in Phase 2)
  consults `supports?/3` to decide whether to dispatch a non-text
  envelope to a downstream plugin.

  An absent `media_types` block in a plugin manifest = the plugin is
  not registered here = `supports?/3` returns false for any
  (direction, media_type) pair = the plugin is treated as text-only.

  See spec `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md`
  decisions D5 + §"Routing-layer capability resolve".
  """
  use GenServer

  @table :esr_resource_media_plugin_registry

  @type direction :: :inbound | :outbound

  # ---- Public API ----

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec register(String.t(), %{inbound: [atom()], outbound: [atom()]}) :: :ok
  def register(plugin_name, %{inbound: _, outbound: _} = caps) when is_binary(plugin_name) do
    GenServer.call(__MODULE__, {:register, plugin_name, caps})
  end

  @spec unregister(String.t()) :: :ok
  def unregister(plugin_name) when is_binary(plugin_name) do
    GenServer.call(__MODULE__, {:unregister, plugin_name})
  end

  @spec lookup(String.t()) ::
          {:ok, %{inbound: [atom()], outbound: [atom()]}}
          | {:error, :not_registered}
  def lookup(plugin_name) when is_binary(plugin_name) do
    case :ets.lookup(@table, plugin_name) do
      [{^plugin_name, caps}] -> {:ok, caps}
      [] -> {:error, :not_registered}
    end
  end

  @spec supports?(String.t(), direction(), atom()) :: boolean()
  def supports?(plugin_name, direction, media_type)
      when is_binary(plugin_name) and direction in [:inbound, :outbound] and is_atom(media_type) do
    case lookup(plugin_name) do
      {:ok, caps} -> media_type in Map.fetch!(caps, direction)
      {:error, :not_registered} -> false
    end
  end

  # ---- GenServer ----

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, caps}, _from, state) do
    :ets.insert(@table, {name, caps})
    {:reply, :ok, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end
end
