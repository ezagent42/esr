defmodule Esr.Peers.PtyProcessTest do
  @moduledoc """
  PR-22 — PtyProcess unit tests.

  - on_raw_stdout/2 broadcasts to PubSub topic pty:<sid> as raw bytes
    (no line-splitting; xterm.js needs ANSI escapes intact).
  - on_terminate/1 broadcasts a bare :pty_closed sentinel so attached
    LiveViews can render an "ended" overlay.
  - rewire_session_siblings/1 patches sibling peers' state.neighbors
    under the :pty_process key (mirrors PR-21ω' for tmux).

  Live spawn of the OS process (erlexec :pty + claude) is exercised by
  the e2e scenario `tests/e2e/scenarios/06_pty_attach.sh`, not here.
  """

  use ExUnit.Case, async: false

  alias Esr.Peers.PtyProcess

  setup do
    sid = "test-pty-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> sid)
    {:ok, sid: sid}
  end

  describe "on_raw_stdout/2" do
    test "broadcasts raw chunk as {:pty_stdout, chunk} on pty:<sid>", %{sid: sid} do
      state = %{session_id: sid}
      chunk = "\e[31mhello\e[0m"

      assert :ok = PtyProcess.on_raw_stdout(chunk, state)
      assert_receive {:pty_stdout, ^chunk}, 200
    end

    test "no-op when session_id is missing or empty" do
      assert :ok = PtyProcess.on_raw_stdout("data", %{session_id: nil})
      assert :ok = PtyProcess.on_raw_stdout("data", %{session_id: ""})
      assert :ok = PtyProcess.on_raw_stdout("data", %{})
      refute_receive {:pty_stdout, _}, 50
    end
  end

  describe "on_terminate/1" do
    test "broadcasts bare :pty_closed when session_id is present", %{sid: sid} do
      state = %{session_id: sid}
      assert :ok = PtyProcess.on_terminate(state)
      assert_receive :pty_closed, 200
    end

    test "no-op when session_id is missing" do
      assert :ok = PtyProcess.on_terminate(%{session_id: nil})
      refute_receive :pty_closed, 50
    end
  end

  describe "on_os_exit/2" do
    test "any exit code stops with a reason (triggers DynamicSupervisor restart)" do
      state = %{session_id: "x"}
      assert {:stop, :pty_died_unexpectedly} = PtyProcess.on_os_exit(0, state)
      assert {:stop, {:pty_crashed, 137}} = PtyProcess.on_os_exit(137, state)
    end
  end

  describe "rewire_session_siblings/1" do
    defmodule StubPeer do
      use GenServer
      def start_link(args), do: GenServer.start_link(__MODULE__, args)
      @impl true
      def init(args), do: {:ok, args}
    end

    test "patches sibling peers' neighbors[:pty_process] with our pid" do
      sid = "test-rewire-#{System.unique_integer([:positive])}"
      peers_sup_name = {:via, Registry, {Esr.Session.Registry, {:peers_sup, sid}}}
      {:ok, sup_pid} = DynamicSupervisor.start_link(strategy: :one_for_one, name: peers_sup_name)

      on_exit(fn ->
        if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
      end)

      dead_old = spawn(fn -> :ok end)
      Process.exit(dead_old, :kill)

      {:ok, stub_fcp} =
        DynamicSupervisor.start_child(
          sup_pid,
          %{
            id: :stub_fcp,
            start: {StubPeer, :start_link, [%{neighbors: [pty_process: dead_old, role: :fcp]}]}
          }
        )

      {:ok, stub_cc} =
        DynamicSupervisor.start_child(
          sup_pid,
          %{
            id: :stub_cc,
            start: {StubPeer, :start_link, [%{neighbors: [pty_process: dead_old, role: :cc]}]}
          }
        )

      assert :sys.get_state(stub_fcp).neighbors[:pty_process] == dead_old

      test_pid = self()

      {:ok, fake_pty_pid} =
        DynamicSupervisor.start_child(
          sup_pid,
          %{
            id: :fake_pty,
            start:
              {Task, :start_link,
               [
                 fn ->
                   PtyProcess.rewire_session_siblings(%{session_id: sid})
                   send(test_pid, {:rewire_done, self()})
                   :timer.sleep(:infinity)
                 end
               ]}
          }
        )

      assert_receive {:rewire_done, ^fake_pty_pid}, 500

      assert :sys.get_state(stub_fcp).neighbors[:pty_process] == fake_pty_pid
      assert :sys.get_state(stub_cc).neighbors[:pty_process] == fake_pty_pid
      assert :sys.get_state(stub_fcp).neighbors[:role] == :fcp
      assert :sys.get_state(stub_cc).neighbors[:role] == :cc
    end
  end
end
