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
  @artifact_table :esr_topology_artifacts

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
    handle = %Handle{name: name, params: params, peer_ids: peer_ids}

    # S7: `:ets.insert_new/2` is atomic — no TOCTOU between lookup and
    # insert. If the key was already present, read the winning handle.
    if :ets.insert_new(@table, {key, handle}) do
      {:ok, handle}
    else
      [{^key, existing}] = :ets.lookup(@table, key)
      {:ok, existing}
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

  @doc """
  Store a compiled topology artifact by name. PeerServer's
  `invoke_command` action looks these up before handing off to
  `Esr.Topology.Instantiator.instantiate/2`.
  """
  @spec put_artifact(String.t(), map()) :: :ok
  def put_artifact(name, artifact) when is_binary(name) and is_map(artifact) do
    :ets.insert(@artifact_table, {name, artifact})
    :ok
  end

  @spec get_artifact(String.t()) :: {:ok, map()} | :error
  def get_artifact(name) when is_binary(name) do
    case :ets.lookup(@artifact_table, name) do
      [{^name, artifact}] -> {:ok, artifact}
      [] -> :error
    end
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
    :ets.new(@artifact_table, [:named_table, :public, :set, read_concurrency: true])
    # Bootstrap artifact registry from the default esrd instance's
    # ``commands/.compiled/*.yaml`` dir. Handlers fire InvokeCommand
    # actions by name, and without a pre-populated registry the dispatch
    # silently drops (no cmd run was invoked for the secondary
    # pattern). On --live the /new-thread handler emits InvokeCommand
    # for ``feishu-thread-session`` without the CLI ever running
    # ``esr cmd run`` for it — this scan closes the gap.
    #
    # Disabled via :esr :bootstrap_artifacts false (test suite sets
    # this in config/test.exs) so per-test empty-registry expectations
    # still hold.
    if Application.get_env(:esr, :bootstrap_artifacts, true) do
      load_artifacts_from_dir()
    end
    {:ok, %{}}
  end

  defp load_artifacts_from_dir do
    dir = Esr.Paths.commands_compiled_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".yaml"))
      |> Enum.each(fn file ->
        path = Path.join(dir, file)

        with {:ok, parsed} <- YamlElixir.read_from_file(path),
             name when is_binary(name) <- Map.get(parsed, "name") do
          :ets.insert(@artifact_table, {name, parsed})
        end
      end)
    end
  end

  # ------------------------------------------------------------------
  # Canonical key — params order-independent.
  # ------------------------------------------------------------------

  defp key_for(name, params) do
    canonical = params |> Map.to_list() |> Enum.sort()
    {name, canonical}
  end
end
