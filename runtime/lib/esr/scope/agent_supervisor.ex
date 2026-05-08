defmodule Esr.Scope.AgentSupervisor do
  @moduledoc """
  Per-session DynamicSupervisor hosting agent instance subtrees.

  Each call to `/session:add-agent` adds one child: a `:one_for_all`
  Supervisor (`Esr.Scope.AgentInstanceSupervisor`) containing exactly two
  workers — `Esr.Entity.CCProcess` (in `runtime/lib/esr/plugins/claude_code/`) and
  `Esr.Entity.PtyProcess`.

  The `:one_for_all` strategy ensures CC and PTY are always restarted
  together: if PTY crashes, CC has no output path; if CC crashes, PTY
  has no consumer. Lone-survivor state has no semantic value.

  Restart intensity: `max_restarts: 3, max_seconds: 60` per agent
  instance supervisor. If an agent subtree trips the restart budget,
  the instance is terminated. The operator must re-add it via
  `/session:add-agent`. This prevents tight crash loops.

  Locked decision Q5.3 sub-2 and sub-3 (Feishu 2026-05-07).
  """

  use DynamicSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Add a (CC, PTY) `:one_for_all` subtree for a named agent instance.

  `attrs` must contain:
  - `session_id` — the session this agent belongs to
  - `name` — operator-facing agent name (must be unique in session)
  - `cc_args` — args map forwarded to CCProcess.start_link/1
  - `pty_args` — args map forwarded to PtyProcess.start_link/1

  Returns `{:ok, instance_sup_pid}` on success, `{:error, reason}` on failure.
  """
  @spec add_agent_subtree(sup :: pid() | atom() | tuple(), attrs :: map()) ::
          {:ok, pid()} | {:error, term()}
  def add_agent_subtree(sup \\ __MODULE__, attrs) do
    sid = Map.fetch!(attrs, :session_id)
    name = Map.fetch!(attrs, :name)
    cc_args = Map.fetch!(attrs, :cc_args)
    pty_args = Map.fetch!(attrs, :pty_args)

    child_spec = %{
      id: {Esr.Scope.AgentInstanceSupervisor, sid, name},
      start:
        {Esr.Scope.AgentInstanceSupervisor, :start_link,
         [
           %{
             session_id: sid,
             name: name,
             cc_args: cc_args,
             pty_args: pty_args
           }
         ]},
      restart: :transient,
      type: :supervisor
    }

    DynamicSupervisor.start_child(sup, child_spec)
  end

  @doc """
  Remove and stop the agent instance supervisor.

  Cascades via OTP: instance supervisor terminates → CC and PTY
  `terminate/2` callbacks fire → `deregister_attrs/2` cleans Index 2 + 3
  → Registry monitors clean Index 1.
  """
  @spec remove_agent_subtree(sup :: pid() | atom() | tuple(), instance_sup_pid :: pid()) ::
          :ok | {:error, term()}
  def remove_agent_subtree(sup \\ __MODULE__, instance_sup_pid) when is_pid(instance_sup_pid) do
    DynamicSupervisor.terminate_child(sup, instance_sup_pid)
  end
end
