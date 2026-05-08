defmodule Esr.Scope.AgentInstanceSupervisor do
  @moduledoc """
  Per-agent-instance `:one_for_all` Supervisor hosting CC + PTY.

  If either child crashes, both are restarted together. This enforces
  the invariant that CC (the AI process) and PTY (its IO channel) are
  always in a consistent state. Lone-survivor restart is explicitly
  prohibited — spec Q5.3 sub-2 (Feishu 2026-05-07).

  Restart intensity: `max_restarts: 3, max_seconds: 60`. If the subtree
  trips this budget, the supervisor exits with reason `:shutdown`. The
  parent `Esr.Scope.AgentSupervisor`'s `:transient` child spec means it
  is NOT restarted automatically; the operator must call
  `/session:add-agent` again.
  """

  use Supervisor

  def start_link(%{session_id: _sid, name: _name, cc_args: _cc, pty_args: _pty} = args) do
    Supervisor.start_link(__MODULE__, args, [])
  end

  @impl true
  def init(%{cc_args: cc_args, pty_args: pty_args}) do
    children = [
      %{
        id: Esr.Entity.CCProcess,
        start: {Esr.Entity.CCProcess, :start_link, [cc_args]},
        restart: :permanent,
        type: :worker
      },
      %{
        id: Esr.Entity.PtyProcess,
        start: {Esr.Entity.PtyProcess, :start_link, [pty_args]},
        restart: :permanent,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 60)
  end
end
