defmodule Esr.Entity.Factory do
  @moduledoc """
  Creation mechanics for Peers. Thin wrapper over `DynamicSupervisor.start_child`.

  **Hard rule:** this module MUST NOT contain routing/lookup/decision logic.
  Its public surface is exactly three functions: `spawn_peer/5`,
  `terminate_peer/2`, `restart_peer/2`. Review rejects additions.

  The factory resolves `session_id` to the correct Session supervisor by
  delegating to `Esr.Scope.supervisor_name/1` (registry-backed in PR-2).
  An opt-in app-env override (`:esr, :peer_factory_sup_override`) is
  retained for unit tests that don't stand up a real Session; PR-3 removes
  this last scaffold once all tests use real Sessions.

  See spec §3.3, §5.4, and §6 Risk A.
  """
  require Logger

  @spec spawn_peer(session_id :: String.t(), mod :: module(), args :: map(), neighbors :: list(), ctx :: map()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_peer(session_id, mod, args, neighbors, ctx) do
    :telemetry.execute([:esr, :peer_factory, :spawn], %{}, %{mod: mod, session_id: session_id})

    if Code.ensure_loaded?(mod) do
      # P3-3a: thread `session_process_pid` into every proxy_ctx so
      # Peer.Proxy's capability-check wrapper can route to
      # Scope.Process.has?/2 (per-session local map) instead of the
      # global Grants GenServer. Resolving the pid here — once, at
      # spawn time — avoids a Registry lookup on every forward/2 call.
      #
      # P6-A2: `session_id` is also threaded into ctx so Peer.Proxy's
      # cap-check can call `Esr.Scope.Process.has?(session_id, perm)`
      # directly (zero-hop persistent_term read). The pid is retained
      # purely as a liveness guard — if the Scope.Process has died,
      # we fall back to the global `Esr.Capabilities.has?/2`.
      ctx_with_sp =
        case resolve_session_process_pid(session_id) do
          nil -> ctx
          pid -> ctx |> Map.put(:session_process_pid, pid) |> Map.put(:session_id, session_id)
        end

      init_args =
        Map.merge(args, %{session_id: session_id, neighbors: neighbors, proxy_ctx: ctx_with_sp})

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

  @doc """
  Bootstrap-time peer spawn that bypasses `Esr.Scope.supervisor_name/1`.

  Only Scope.Admin's init-time children use this — it is the documented
  exception to the "all peers spawn via the normal control plane" rule
  (spec §6 Risk F). The first arg is the literal DynamicSupervisor name
  (not a session_id) because at boot Scope.Admin's children supervisor
  is the only supervisor that can host the peer.
  """
  @spec spawn_peer_bootstrap(sup_name :: atom(), mod :: module(), args :: map(), neighbors :: list()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_peer_bootstrap(sup_name, mod, args, neighbors) when is_atom(sup_name) do
    :telemetry.execute([:esr, :peer_factory, :spawn_bootstrap], %{}, %{mod: mod, sup: sup_name})

    if Code.ensure_loaded?(mod) do
      init_args = Map.merge(args, %{session_id: "admin", neighbors: neighbors, proxy_ctx: %{}})
      DynamicSupervisor.start_child(sup_name, {mod, init_args})
    else
      {:error, {:unknown_impl, mod}}
    end
  end

  # Session supervisor resolution.
  #
  # Production: Esr.Scope.supervisor_name/1 (registry-backed in PR-2).
  # Test-only opt-in override: Application.put_env(:esr, :peer_factory_sup_override, name)
  #   — used in unit tests that don't spin up a real Session. Removed entirely
  #   in PR-3 once all tests use real Sessions.
  defp resolve_sup(session_id) do
    case Application.get_env(:esr, :peer_factory_sup_override) do
      nil -> Esr.Scope.supervisor_name(session_id)
      override -> override
    end
  end

  # Resolve the Scope.Process pid for this session at spawn time so
  # downstream peer's capability checks can target it directly.
  # Returns `nil` for the admin session (no per-session Scope.Process)
  # and when no Scope.Process is registered yet (test setups that
  # spawn peers without a real Session around them — common in early
  # refactor phases).
  defp resolve_session_process_pid("admin"), do: nil

  defp resolve_session_process_pid(session_id) when is_binary(session_id) do
    case Registry.lookup(Esr.Scope.Registry, {:session_process, session_id}) do
      [{pid, _}] -> pid
      _ -> nil
    end
  rescue
    # Registry may not yet exist in isolated unit tests.
    ArgumentError -> nil
  end
end
