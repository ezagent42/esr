defmodule Esr.Uri.Store do
  @moduledoc """
  Single-table URI store. Owns ETS `:esr_uri_store`.

  Row formats (tagged value):
    {uri :: String.t(), {:entity, kind :: atom(), data :: struct()}}
    {uri :: String.t(), {:alias,  canonical_uri :: String.t()}}

  Reads bypass GenServer (direct `:ets.lookup`).
  Writes serialize via GenServer.call to preserve alias→canonical
  1-hop invariant (an alias's target must be a canonical :entity row,
  never another :alias row).

  All URIs use `esr://localhost/...` prefix per Esr.Uri.parse/1 grammar.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §8
  """

  use GenServer

  @table :esr_uri_store

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Direct ETS read; no GenServer round-trip. Returns raw row value."
  @spec lookup_raw(String.t()) :: {:ok, term()} | :not_found
  def lookup_raw(uri) when is_binary(uri) do
    case :ets.lookup(@table, uri) do
      [{^uri, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc "Write entity row (canonical URI)."
  @spec put_entity(String.t(), atom(), struct()) :: :ok
  def put_entity(canonical_uri, kind, data)
      when is_binary(canonical_uri) and is_atom(kind) and is_struct(data) do
    GenServer.call(__MODULE__, {:put_entity, canonical_uri, kind, data})
  end

  @doc "Write alias row pointing to a canonical entity URI."
  @spec put_alias(String.t(), String.t()) ::
          :ok | {:error, :canonical_missing | :target_is_alias | :alias_exists}
  def put_alias(alias_uri, canonical_uri)
      when is_binary(alias_uri) and is_binary(canonical_uri) do
    GenServer.call(__MODULE__, {:put_alias, alias_uri, canonical_uri})
  end

  @doc "Delete row by URI."
  @spec delete(String.t()) :: :ok
  def delete(uri) when is_binary(uri) do
    GenServer.call(__MODULE__, {:delete, uri})
  end

  # ──────────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_entity, uri, kind, data}, _from, state) do
    :ets.insert(@table, {uri, {:entity, kind, data}})
    {:reply, :ok, state}
  end

  def handle_call({:put_alias, alias_uri, canonical_uri}, _from, state) do
    case :ets.lookup(@table, canonical_uri) do
      [{^canonical_uri, {:entity, _, _}}] ->
        case :ets.lookup(@table, alias_uri) do
          [] ->
            :ets.insert(@table, {alias_uri, {:alias, canonical_uri}})
            {:reply, :ok, state}

          _ ->
            {:reply, {:error, :alias_exists}, state}
        end

      [{^canonical_uri, {:alias, _}}] ->
        {:reply, {:error, :target_is_alias}, state}

      [] ->
        {:reply, {:error, :canonical_missing}, state}
    end
  end

  def handle_call({:delete, uri}, _from, state) do
    :ets.delete(@table, uri)
    {:reply, :ok, state}
  end
end
