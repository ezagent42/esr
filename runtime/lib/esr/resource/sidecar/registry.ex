defmodule Esr.Resource.Sidecar.Registry do
  @moduledoc """
  Maps `adapter_type :: String.t()` → `python_module :: String.t()`.

  Today's `Esr.WorkerSupervisor.sidecar_module/1` hard-coded the
  feishu / cc_mcp dispatch table. After plugin work lands, plugins
  declare their sidecar mappings via manifest; this registry is the
  composed runtime view.

  Phase-1 use: `Esr.Application.start/2` registers fallback mappings
  at boot (so existing tests keep passing). Once plugins ship their
  manifest declarations, those plugins call `register/2` at startup
  and the fallbacks become redundant.

  Falls through to `generic_adapter_runner` on miss (matches today's
  behaviour). See `docs/superpowers/specs/2026-05-04-core-decoupling-design.md` §四.
  """

  use GenServer

  @table :esr_sidecar_registry

  ## Public API

  @doc "Start the registry. Registered globally as `__MODULE__`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Register a sidecar mapping. Idempotent; later calls overwrite.
  Returns `:ok` (the call is synchronous so writes are visible to
  subsequent lookups).
  """
  @spec register(adapter_type :: String.t(), python_module :: String.t()) :: :ok
  def register(adapter_type, python_module)
      when is_binary(adapter_type) and is_binary(python_module) do
    GenServer.call(__MODULE__, {:register, adapter_type, python_module})
  end

  @doc "Remove a mapping. Idempotent."
  @spec unregister(adapter_type :: String.t()) :: :ok
  def unregister(adapter_type) when is_binary(adapter_type) do
    GenServer.call(__MODULE__, {:unregister, adapter_type})
  end

  @doc """
  Look up the python module for `adapter_type`. Returns `:error`
  on miss (caller decides fallback). Reads ETS directly (no
  GenServer mailbox).
  """
  @spec lookup(adapter_type :: String.t()) :: {:ok, String.t()} | :error
  def lookup(adapter_type) when is_binary(adapter_type) do
    case :ets.lookup(@table, adapter_type) do
      [{^adapter_type, python_module}] -> {:ok, python_module}
      [] -> :error
    end
  end

  @doc "List all `{adapter_type, python_module}` pairs."
  @spec list() :: [{String.t(), String.t()}]
  def list do
    :ets.tab2list(@table)
  end

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, adapter_type, python_module}, _from, state) do
    :ets.insert(@table, {adapter_type, python_module})
    {:reply, :ok, state}
  end

  def handle_call({:unregister, adapter_type}, _from, state) do
    :ets.delete(@table, adapter_type)
    {:reply, :ok, state}
  end
end
