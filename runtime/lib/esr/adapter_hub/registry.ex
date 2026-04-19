defmodule Esr.AdapterHub.Registry do
  @moduledoc """
  Binds adapter Phoenix topics (`adapter:<name>/<instance_id>`) to the
  actor_id that owns them (PRD 01 F08, spec §3.3). When an inbound
  event arrives on a Phoenix channel, `AdapterHub` uses this registry
  to find the owning PeerServer.

  Backed by ETS (not Elixir's `Registry`) because the keys are long-
  lived URL-like strings, not process names, and we want cheap
  atomic upsert semantics.

  Public API:
    start_link/1              — no opts; named by module
    bind(topic, actor_id)     — upsert; returns :ok
    unbind(topic)             — idempotent; returns :ok
    lookup(topic)             — {:ok, actor_id} | :error
    list/0                    — [{topic, actor_id}]
  """
  use GenServer

  @table :esr_adapter_hub_bindings

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec bind(String.t(), String.t()) :: :ok
  def bind(topic, actor_id) when is_binary(topic) and is_binary(actor_id) do
    :ets.insert(@table, {topic, actor_id})
    :ok
  end

  @spec unbind(String.t()) :: :ok
  def unbind(topic) when is_binary(topic) do
    :ets.delete(@table, topic)
    :ok
  end

  @spec lookup(String.t()) :: {:ok, String.t()} | :error
  def lookup(topic) when is_binary(topic) do
    case :ets.lookup(@table, topic) do
      [{^topic, actor_id}] -> {:ok, actor_id}
      [] -> :error
    end
  end

  @spec list() :: [{String.t(), String.t()}]
  def list, do: :ets.tab2list(@table)

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
