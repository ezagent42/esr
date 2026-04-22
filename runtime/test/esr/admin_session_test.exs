defmodule Esr.AdminSessionTest do
  use ExUnit.Case, async: false

  setup do
    # Isolated start so the app-level AdminSession does not conflict.
    # We start the supervisor directly under a throwaway name and let
    # it bring up its own AdminSessionProcess child (registered under
    # Esr.AdminSessionProcess — the module-level name the real code uses).
    #
    # NOTE: the PR-2 expansion setup also included a redundant
    # `start_supervised!({Esr.AdminSessionProcess, []})` above the
    # `Esr.AdminSession.start_link/1` call. That would double-register
    # the same GenServer name and crash the supervisor with
    # `:already_started`. Removed here to preserve the expansion's
    # actual intent (one AdminSessionProcess, owned by the supervisor).
    {:ok, sup} =
      Esr.AdminSession.start_link(
        name: :test_admin_session,
        children_sup_name: :test_admin_children_sup,
        process_name: Esr.AdminSessionProcess
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

    {:ok, sup: sup}
  end

  test "AdminSession starts AdminSessionProcess", _ctx do
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
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

  test "AdminSession starts even when Esr.SessionRouter is not loaded" do
    # Risk F boot-order test: AdminSession must not depend on SessionRouter
    refute Code.ensure_loaded?(Esr.SessionRouter),
           "Esr.SessionRouter must not be loaded for this test (it's introduced in PR-3)"

    assert Process.alive?(Process.whereis(Esr.AdminSessionProcess))
  end
end
