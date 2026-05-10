defmodule Esr.Channel.Registry do
  @moduledoc """
  ETS-backed registry mapping `<plugin>.<channel_name>` → module.
  Populated at plugin boot (`Esr.Plugin.Loader` reads each plugin's
  `manifest.yaml` `channels:` block); read concurrently by SessionTemplate
  loader during template registration (Phase 4).

  Public read API (`lookup/1`, `list_kinds/0`) is ETS-direct, no
  GenServer hop. The GenServer only owns the ETS table lifecycle.

  History: 2026-05-10 spec, Phase 1.
  """

  use GenServer

  @table :esr_channel_kinds

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Register a channel kind. `key` is `<plugin>.<channel_name>`.
  Idempotent: re-registering the same key replaces the module.
  """
  @spec register(String.t(), String.t(), module()) :: :ok
  def register(plugin, channel_name, module)
      when is_binary(plugin) and is_binary(channel_name) and is_atom(module) do
    :ets.insert(@table, {"#{plugin}.#{channel_name}", module})
    :ok
  end

  @doc "Look up a channel kind by `<plugin>.<channel_name>`."
  @spec lookup(String.t()) :: {:ok, module()} | :not_found
  def lookup(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, module}] -> {:ok, module}
      [] -> :not_found
    end
  end

  @doc "Return every registered `{<plugin>.<channel_name>, module}` pair."
  @spec list_kinds() :: [{String.t(), module()}]
  def list_kinds do
    :ets.tab2list(@table)
  end

  @doc "Clear all registered kinds. Used by tests + plugin reload."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end
end
