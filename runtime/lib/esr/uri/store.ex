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

  @doc """
  Delete every entity row of the given `kind`, plus every alias whose
  canonical points at one of those rows.

  Used by FileLoader-style callers that own a "snapshot" of a yaml file
  and want to replace it atomically. Note: not strictly atomic w.r.t.
  concurrent reads (the GenServer call serializes the deletes, but a
  reader between handle_call iterations may see partial state). For
  PR-1's boot-time semantics this is acceptable.
  """
  @spec delete_all_by_kind(atom()) :: :ok
  def delete_all_by_kind(kind) when is_atom(kind) do
    GenServer.call(__MODULE__, {:delete_all_by_kind, kind})
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

  def handle_call({:delete_all_by_kind, kind}, _from, state) do
    # Two passes: (1) collect canonical entity URIs of this kind;
    # (2) delete those rows + every alias whose target is in the set.
    canonical_uris =
      :ets.tab2list(@table)
      |> Enum.flat_map(fn
        {uri, {:entity, ^kind, _}} -> [uri]
        _ -> []
      end)

    canonical_set = MapSet.new(canonical_uris)

    Enum.each(:ets.tab2list(@table), fn
      {uri, {:entity, ^kind, _}} ->
        :ets.delete(@table, uri)

      {uri, {:alias, target}} ->
        if MapSet.member?(canonical_set, target), do: :ets.delete(@table, uri)

      _ ->
        :ok
    end)

    {:reply, :ok, state}
  end
end
