defmodule Esr.PeerFactory do
  @moduledoc """
  Creation mechanics for Peers. Thin wrapper over `DynamicSupervisor.start_child`.

  **Hard rule:** this module MUST NOT contain routing/lookup/decision logic.
  Its public surface is exactly three functions: `spawn_peer/5`,
  `terminate_peer/2`, `restart_peer/2`. Review rejects additions.

  The factory resolves `session_id` to the correct Session supervisor
  via a convention: `via_tuple(session_id)` returning `{:via, Registry, {Esr.SessionRegistry.Via, {:session_sup, session_id}}}`.
  The test helper may override via `Process.put(:peer_factory_sup_override, name)`.

  See spec §3.3, §5.4, and §6 Risk A.
  """
  require Logger

  @spec spawn_peer(session_id :: String.t(), mod :: module(), args :: map(), neighbors :: list(), ctx :: map()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_peer(session_id, mod, args, neighbors, ctx) do
    :telemetry.execute([:esr, :peer_factory, :spawn], %{}, %{mod: mod, session_id: session_id})

    if Code.ensure_loaded?(mod) do
      init_args = Map.merge(args, %{session_id: session_id, neighbors: neighbors, proxy_ctx: ctx})
      DynamicSupervisor.start_child(resolve_sup(session_id), {mod, init_args})
    else
      {:error, {:unknown_impl, mod}}
    end
  end

  @spec terminate_peer(session_id :: String.t(), pid :: pid()) :: :ok | {:error, term()}
  def terminate_peer(session_id, pid) do
    DynamicSupervisor.terminate_child(resolve_sup(session_id), pid)
  end

  @spec restart_peer(session_id :: String.t(), spec :: term()) :: {:ok, pid()} | {:error, term()}
  def restart_peer(session_id, spec) do
    DynamicSupervisor.start_child(resolve_sup(session_id), spec)
  end

  # Session supervisor resolution. In PR-1, only the test-override path
  # is used; PR-2 introduces Esr.Session.supervisor_name/1 for the real
  # AdminSession / SessionsSupervisor lookup.
  defp resolve_sup(session_id) do
    case Process.get(:peer_factory_sup_override) do
      nil -> Esr.Session.supervisor_name(session_id)
      override -> override
    end
  end
end
