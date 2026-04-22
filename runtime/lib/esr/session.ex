defmodule Esr.Session do
  @moduledoc """
  Supervisor module for a per-user Session subtree. Strategy :one_for_all,
  :transient (spec §3.5).

  Children:
    1. Esr.SessionProcess (:permanent)
    2. A DynamicSupervisor named via the Session.Registry under
       {:peers_sup, session_id} — hosts all peers in the agent's pipeline.
       PeerFactory.spawn_peer/5 resolves to this supervisor via
       Esr.Session.supervisor_name/1.

  The AdminSession's children supervisor is a special case: for session_id
  == "admin", supervisor_name/1 returns the atom configured in
  :esr, :admin_children_sup_name (populated by Esr.AdminSession.init/1).

  Spec §3.5, §7.
  """
  use Supervisor

  def start_link(%{session_id: sid} = args) do
    Supervisor.start_link(__MODULE__, args, name: via_sup(sid))
  end

  defp via_sup(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:session_sup, session_id}}}

  def supervisor_name("admin"),
    do: Application.get_env(:esr, :admin_children_sup_name, Esr.AdminSession.ChildrenSupervisor)

  def supervisor_name(session_id) when is_binary(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:peers_sup, session_id}}}

  @impl true
  def init(args) do
    sid = Map.fetch!(args, :session_id)

    peers_sup_name =
      {:via, Registry, {Esr.Session.Registry, {:peers_sup, sid}}}

    children = [
      %{
        id: Esr.SessionProcess,
        start: {Esr.SessionProcess, :start_link, [args]},
        restart: :permanent,
        type: :worker
      },
      %{
        id: :peers,
        start:
          {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: peers_sup_name]]},
        restart: :permanent,
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
