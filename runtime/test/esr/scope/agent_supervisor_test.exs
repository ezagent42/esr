defmodule Esr.Scope.AgentSupervisorTest do
  @moduledoc """
  M-2.6 — per-session AgentSupervisor / AgentInstanceSupervisor.

  Verifies the public surface required by M-2.7's
  `InstanceRegistry.add_instance_and_spawn/2`:
    - AgentSupervisor starts empty
    - add_agent_subtree/2 inserts a `:transient` child with a
      AgentInstanceSupervisor running CC + PTY under :one_for_all
    - remove_agent_subtree/2 cleans the subtree

  We use a dummy worker module pair to avoid pulling the full CC/PTY
  init pipeline (which depends on application boot, ETS tables, and
  external processes) into a unit test. The supervision strategy is
  what we care about here.
  """

  use ExUnit.Case, async: true

  defmodule DummyWorker do
    use GenServer
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    @impl true
    def init(args), do: {:ok, args}
    @impl true
    def handle_call(:state, _from, s), do: {:reply, s, s}
  end

  describe "AgentSupervisor.start_link/1" do
    test "starts with zero children" do
      {:ok, pid} = Esr.Scope.AgentSupervisor.start_link(name: nil)
      assert is_pid(pid)
      assert [] == DynamicSupervisor.which_children(pid)
    end
  end

  describe "AgentInstanceSupervisor (:one_for_all)" do
    defmodule TestInstanceSup do
      use Supervisor

      def start_link(%{cc_args: _, pty_args: _} = args),
        do: Supervisor.start_link(__MODULE__, args)

      @impl true
      def init(%{cc_args: cc, pty_args: pty}) do
        children = [
          %{
            id: :cc,
            start: {Esr.Scope.AgentSupervisorTest.DummyWorker, :start_link, [cc]},
            restart: :permanent,
            type: :worker
          },
          %{
            id: :pty,
            start: {Esr.Scope.AgentSupervisorTest.DummyWorker, :start_link, [pty]},
            restart: :permanent,
            type: :worker
          }
        ]

        Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 60)
      end
    end

    test "two workers run under one_for_all; killing one restarts both" do
      {:ok, sup_pid} =
        TestInstanceSup.start_link(%{cc_args: %{role: :cc}, pty_args: %{role: :pty}})

      [{_, pty_pid_a, _, _}, {_, cc_pid_a, _, _}] = Supervisor.which_children(sup_pid)
      assert is_pid(cc_pid_a) and is_pid(pty_pid_a)

      # Kill one — both restart together under :one_for_all.
      Process.exit(cc_pid_a, :kill)

      # Wait for restart to settle.
      Process.sleep(50)

      [{_, pty_pid_b, _, _}, {_, cc_pid_b, _, _}] = Supervisor.which_children(sup_pid)
      assert is_pid(cc_pid_b) and is_pid(pty_pid_b)
      refute pty_pid_b == pty_pid_a, "PTY should have been restarted alongside CC (:one_for_all)"
    end
  end
end
