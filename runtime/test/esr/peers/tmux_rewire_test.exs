defmodule Esr.Peers.TmuxRewireTest do
  @moduledoc """
  PR-21ψ — when TmuxProcess restarts (peers DynamicSupervisor's
  `:one_for_one` policy auto-restarts on crash), its new pid must be
  pushed back into sibling peers' `state.neighbors[:tmux_process]`
  so subsequent `send_input` actions don't hit the dead pid.

  Pre-PR-21ψ behaviour: TmuxProcess restart left the new pid orphaned;
  FCP and cc_process kept the OLD pid as their `:tmux_process`
  neighbor. Operator-facing UX was "session became silent".

  This test fakes the supervision context — it runs a real
  `DynamicSupervisor` registered under
  `{:peers_sup, "test-rewire-sid"}` in `Esr.Session.Registry`,
  spawns synthetic peer GenServers under it, then directly invokes
  TmuxProcess's init flow (which triggers `rewire_session_siblings/1`)
  and asserts the stubs got patched.
  """

  use ExUnit.Case, async: false

  alias Esr.Peers.TmuxProcess

  defmodule StubPeer do
    @moduledoc false
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    @impl true
    def init(args), do: {:ok, args}
  end

  setup do
    sid = "test-rewire-#{System.unique_integer([:positive])}"

    peers_sup_name = {:via, Registry, {Esr.Session.Registry, {:peers_sup, sid}}}
    {:ok, sup_pid} = DynamicSupervisor.start_link(strategy: :one_for_one, name: peers_sup_name)

    on_exit(fn ->
      if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
    end)

    {:ok, sid: sid, sup_pid: sup_pid}
  end

  test "TmuxProcess.init pushes new pid into siblings' neighbors[:tmux_process]",
       %{sid: sid, sup_pid: sup_pid} do
    # Synthetic FCP + cc_process stubs with a plain (non-OSProcess-wrapped)
    # state shape — just `%{neighbors: [...]}`. Their initial neighbors
    # map carries an OLD :tmux_process pid that no longer exists.
    dead_old = spawn(fn -> :ok end)
    Process.exit(dead_old, :kill)

    {:ok, stub_fcp} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :stub_fcp,
          start: {StubPeer, :start_link, [%{neighbors: [tmux_process: dead_old, role: :fcp]}]}
        }
      )

    {:ok, stub_cc} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :stub_cc,
          start: {StubPeer, :start_link, [%{neighbors: [tmux_process: dead_old, role: :cc]}]}
        }
      )

    # Pre-condition: both stubs hold the dead old pid.
    assert :sys.get_state(stub_fcp).neighbors[:tmux_process] == dead_old
    assert :sys.get_state(stub_cc).neighbors[:tmux_process] == dead_old

    # Run TmuxProcess.init in a synthetic GenServer so `self()` in the
    # init body is a real pid we can capture. We don't go through
    # OSProcessWorker.start_link (which would actually spawn tmux);
    # we just invoke TmuxProcess.init/1 to exercise rewire_session_siblings.
    test_pid = self()

    {:ok, tmux_pid} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :tmux_under_test,
          start:
            {Task, :start_link,
             [
               fn ->
                 _ =
                   TmuxProcess.init(%{
                     session_name: "esr_cc_test_#{System.unique_integer([:positive])}",
                     dir: "/tmp",
                     session_id: sid,
                     start_cmd: "sh -c 'sleep 60'"
                   })

                 send(test_pid, {:tmux_init_done, self()})
                 # Stay alive so we have a stable pid for the assertions.
                 :timer.sleep(:infinity)
               end
             ]}
        }
      )

    assert_receive {:tmux_init_done, ^tmux_pid}, 500

    # Both stubs should now have tmux_pid as their :tmux_process neighbor.
    assert :sys.get_state(stub_fcp).neighbors[:tmux_process] == tmux_pid
    assert :sys.get_state(stub_cc).neighbors[:tmux_process] == tmux_pid

    # And the role marker is preserved (we didn't trample other neighbors).
    assert :sys.get_state(stub_fcp).neighbors[:role] == :fcp
    assert :sys.get_state(stub_cc).neighbors[:role] == :cc
  end
end
