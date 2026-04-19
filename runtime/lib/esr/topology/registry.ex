defmodule Esr.Topology.Registry do
  @moduledoc """
  ETS-backed registry of live topology instantiations (PRD 01 F13).

  Each handle is keyed by ``{name, canonical_params}`` — registering
  the same ``(name, params)`` pair is idempotent and returns the
  existing handle. Used by ``Esr.Topology.Instantiator`` to avoid
  re-spawning an already-live topology and by ``esr cmd stop/restart``
  (PRD 07 F12/F13) to find handles to tear down.
  """

  use GenServer

  alias Esr.Topology.Registry.Handle

  @table :esr_topology_handles

  defmodule Handle do
    @moduledoc "Canonical (name, params) pair identifying a live topology."

    @enforce_keys [:name, :params]
    defstruct [:name, :params, peer_ids: []]

    @type t :: %__MODULE__{
            name: String.t(),
            params: map(),
            peer_ids: [String.t()]
          }
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec register(String.t(), map(), [String.t()]) :: {:ok, Handle.t()}
  def register(name, params, peer_ids \\ [])
      when is_binary(name) and is_map(params) and is_list(peer_ids) do
    key = key_for(name, params)

    case :ets.lookup(@table, key) do
      [{^key, handle}] ->
        {:ok, handle}

      [] ->
        handle = %Handle{name: name, params: params, peer_ids: peer_ids}
        :ets.insert(@table, {key, handle})
        {:ok, handle}
    end
  end

  @spec lookup(String.t(), map()) :: {:ok, Handle.t()} | :error
  def lookup(name, params) when is_binary(name) and is_map(params) do
    case :ets.lookup(@table, key_for(name, params)) do
      [{_key, handle}] -> {:ok, handle}
      [] -> :error
    end
  end

  @spec list_all() :: [Handle.t()]
  def list_all do
    :ets.tab2list(@table) |> Enum.map(fn {_k, handle} -> handle end)
  end

  @spec deactivate(Handle.t()) :: :ok
  def deactivate(%Handle{name: name, params: params, peer_ids: peer_ids}) do
    # Reverse topo order: dependents first, then their parents (PRD 01 F14).
    for id <- Enum.reverse(peer_ids) do
      Esr.PeerSupervisor.stop_peer(id)
    end

    :ets.delete(@table, key_for(name, params))

    :telemetry.execute([:esr, :topology, :deactivated], %{}, %{
      name: name,
      params: params,
      peer_ids: peer_ids
    })

    :ok
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  # ------------------------------------------------------------------
  # Canonical key — params order-independent.
  # ------------------------------------------------------------------

  defp key_for(name, params) do
    canonical = params |> Map.to_list() |> Enum.sort()
    {name, canonical}
  end
end
