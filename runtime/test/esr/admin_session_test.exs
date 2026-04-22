defmodule Esr.AdminSessionTest do
  use ExUnit.Case, async: false

  setup do
    # Drift from expansion doc: P2-9 added `Esr.AdminSession` to
    # `Esr.Application`'s supervision tree, registering
    # `Esr.AdminSessionProcess` and `Esr.AdminSession.ChildrenSupervisor`
    # at app boot. To keep these tests hermetic and avoid the
    # `:already_started` collision, we start a second, isolated
    # AdminSession tree under test-only names for every assertion
    # here. The app-level process is left untouched.
    test_process_name = :"test_admin_session_process_#{:erlang.unique_integer([:positive])}"

    {:ok, sup} =
      Esr.AdminSession.start_link(
        name: :test_admin_session,
        children_sup_name: :test_admin_children_sup,
        process_name: test_process_name
      )

    on_exit(fn ->
      if Process.alive?(sup) do
        ref = Process.monitor(sup)
        Process.exit(sup, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^sup, _} -> :ok
        after
          2_000 -> :ok
        end
      end
    end)

    {:ok, sup: sup, admin_process: test_process_name}
  end

  test "AdminSession starts AdminSessionProcess", %{admin_process: name} do
    assert is_pid(Process.whereis(name))
  end

  test "AdminSession.children_supervisor/1 returns the DynamicSupervisor for admin peers" do
    assert is_atom(Esr.AdminSession.children_supervisor_name(:test_admin_session))
    # ChildrenSupervisor is a DynamicSupervisor for admin-scope peers
    assert is_pid(Process.whereis(:test_admin_children_sup))
  end

  test "PeerFactory.spawn_peer_bootstrap/4 bypasses Session.supervisor_name/1" do
    defmodule DummyAdminPeer do
      use Esr.Peer.Stateful
      use GenServer
      def start_link(args), do: GenServer.start_link(__MODULE__, args)
      def init(args), do: {:ok, args}
      def handle_upstream(_, s), do: {:forward, [], s}
      def handle_downstream(_, s), do: {:forward, [], s}
      def handle_call(_, _, s), do: {:reply, :ok, s}
    end

    assert {:ok, pid} =
             Esr.PeerFactory.spawn_peer_bootstrap(
               :test_admin_children_sup,
               DummyAdminPeer,
               %{},
               []
             )

    assert Process.alive?(pid)
  end

  test "AdminSession starts even when Esr.SessionRouter is not loaded", %{admin_process: name} do
    # Risk F boot-order test: AdminSession must not depend on SessionRouter
    refute Code.ensure_loaded?(Esr.SessionRouter),
           "Esr.SessionRouter must not be loaded for this test (it's introduced in PR-3)"

    assert Process.alive?(Process.whereis(name))
  end
end
