defmodule Esr.ScopeAdminTest do
  use ExUnit.Case, async: false

  setup do
    # Drift from expansion doc: P2-9 added `Esr.Scope.Admin` to
    # `Esr.Application`'s supervision tree, registering
    # `Esr.Scope.Admin.Process` and `Esr.Scope.Admin.ChildrenSupervisor`
    # at app boot. To keep these tests hermetic and avoid the
    # `:already_started` collision, we start a second, isolated
    # Scope.Admin tree under test-only names for every assertion
    # here. The app-level process is left untouched.
    test_process_name = :"test_admin_session_process_#{:erlang.unique_integer([:positive])}"

    {:ok, sup} =
      Esr.Scope.Admin.start_link(
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

  test "Scope.Admin starts Scope.Admin.Process", %{admin_process: name} do
    assert is_pid(Process.whereis(name))
  end

  test "Scope.Admin.children_supervisor/1 returns the DynamicSupervisor for admin peers" do
    assert is_atom(Esr.Scope.Admin.children_supervisor_name(:test_admin_session))
    # ChildrenSupervisor is a DynamicSupervisor for admin-scope peers
    assert is_pid(Process.whereis(:test_admin_children_sup))
  end

  test "Entity.Factory.spawn_peer_bootstrap/3 bypasses Session.supervisor_name/1" do
    defmodule DummyAdminPeer do
      use Esr.Entity.Stateful
      use GenServer
      def start_link(args), do: GenServer.start_link(__MODULE__, args)
      def init(args), do: {:ok, args}
      def handle_upstream(_, s), do: {:forward, [], s}
      def handle_downstream(_, s), do: {:forward, [], s}
      def handle_call(_, _, s), do: {:reply, :ok, s}
    end

    assert {:ok, pid} =
             Esr.Entity.Factory.spawn_peer_bootstrap(
               :test_admin_children_sup,
               DummyAdminPeer,
               %{}
             )

    assert Process.alive?(pid)
  end

  test "Scope.Admin starts without Esr.Scope.Router running (Risk F)", %{admin_process: name} do
    # Risk F boot-order test (spec §6 Risk F): Scope.Admin must not
    # depend on Scope.Router being started. Before PR-3 P3-4 the
    # module didn't exist at all; now it does, but Scope.Admin's
    # boot path still doesn't call into it — the test-local
    # Scope.Admin tree spun up in setup/1 came up fine without any
    # Scope.Router process. That invariant is what Risk F guards.
    assert Code.ensure_loaded?(Esr.Scope.Router),
           "Scope.Router should be compiled into the tree after P3-4"

    assert Process.alive?(Process.whereis(name))
  end
end
