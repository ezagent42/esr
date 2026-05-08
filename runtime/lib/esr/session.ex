defmodule Esr.Session do
  @moduledoc """
  Supervisor module for a per-user Session subtree. Strategy :one_for_all,
  :transient (spec §3.5).

  Children:
    1. Esr.Session.Process (:permanent)
    2. A DynamicSupervisor named via the Session.Registry under
       {:peers_sup, session_id} — hosts all peers in the agent's pipeline.
       Entity.Factory.spawn_peer/4 resolves to this supervisor via
       Esr.Session.supervisor_name/1.
    3. Esr.Session.AgentSupervisor (M-2.6) named via Session.Registry
       under {:agent_sup, session_id} — hosts per-agent-instance
       (CC, PTY) :one_for_all subtrees added via /session:add-agent.

  The Scope.Admin's children supervisor is a special case: for session_id
  == "admin", supervisor_name/1 returns the atom configured in
  :esr, :admin_children_sup_name (populated by Esr.Session.Admin.init/1).

  Spec §3.5, §7.
  """
  use Supervisor

  def start_link(%{session_id: sid} = args) do
    Supervisor.start_link(__MODULE__, args, name: via_sup(sid))
  end

  defp via_sup(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:session_sup, session_id}}}

  def supervisor_name("admin"),
    do: Application.get_env(:esr, :admin_children_sup_name, Esr.Session.Admin.ChildrenSupervisor)

  def supervisor_name(session_id) when is_binary(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:peers_sup, session_id}}}

  @impl true
  def init(args) do
    sid = Map.fetch!(args, :session_id)

    peers_sup_name =
      {:via, Registry, {Esr.Session.Registry, {:peers_sup, sid}}}

    agent_sup_name =
      {:via, Registry, {Esr.Session.Registry, {:agent_sup, sid}}}

    children = [
      %{
        id: Esr.Session.Process,
        start: {Esr.Session.Process, :start_link, [args]},
        restart: :permanent,
        type: :worker
      },
      %{
        id: :peers,
        start:
          {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: peers_sup_name]]},
        restart: :permanent,
        type: :supervisor
      },
      %{
        id: Esr.Session.AgentSupervisor,
        start: {Esr.Session.AgentSupervisor, :start_link, [[name: agent_sup_name]]},
        restart: :permanent,
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
