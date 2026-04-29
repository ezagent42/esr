defmodule Esr.PeerSupervisor do
  @moduledoc """
  DynamicSupervisor that owns PeerServer processes. One-for-one
  strategy: one actor crashing must never cascade to siblings (spec
  §3.2 + E2E Track D session-isolation invariant).

  Children are PeerServers with `restart: :transient` — normal exit
  does not respawn, but abnormal exit does within this supervisor's
  restart intensity.

  PRD 01 F04.
  """

  @behaviour Esr.Role.OTP
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Spawns a new PeerServer under this supervisor.
  `opts` is forwarded to `Esr.PeerServer.start_link/1`.
  """
  @spec start_peer(keyword()) :: DynamicSupervisor.on_start_child()
  def start_peer(opts) do
    child_spec = %{
      id: Esr.PeerServer,
      start: {Esr.PeerServer, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminates the PeerServer registered under `actor_id`.
  Returns `:ok` on success or `{:error, :not_found}` if no such peer.
  """
  @spec stop_peer(String.t()) :: :ok | {:error, :not_found}
  def stop_peer(actor_id) when is_binary(actor_id) do
    case Esr.PeerRegistry.lookup(actor_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      :error -> {:error, :not_found}
    end
  end
end
