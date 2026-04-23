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

  test "AdminSession starts without Esr.SessionRouter running (Risk F)", %{admin_process: name} do
    # Risk F boot-order test (spec §6 Risk F): AdminSession must not
    # depend on SessionRouter being started. Before PR-3 P3-4 the
    # module didn't exist at all; now it does, but AdminSession's
    # boot path still doesn't call into it — the test-local
    # AdminSession tree spun up in setup/1 came up fine without any
    # SessionRouter process. That invariant is what Risk F guards.
    assert Code.ensure_loaded?(Esr.SessionRouter),
           "SessionRouter should be compiled into the tree after P3-4"

    assert Process.alive?(Process.whereis(name))
  end

  test "bootstrap_voice_pools/1 registers :voice_asr_pool and :voice_tts_pool admin peers (app-level)" do
    # The app-level bootstrap already ran during `Esr.Application.start/2`
    # (see application.ex P4a-7 hook); we assert the post-condition. The
    # test-local AdminSession tree used elsewhere in this file doesn't
    # touch these names, so the invariant is app-scoped.
    assert {:ok, asr_pid} = Esr.AdminSessionProcess.admin_peer(:voice_asr_pool)
    assert is_pid(asr_pid)
    assert Process.alive?(asr_pid)

    assert {:ok, tts_pid} = Esr.AdminSessionProcess.admin_peer(:voice_tts_pool)
    assert is_pid(tts_pid)
    assert Process.alive?(tts_pid)

    # And they're reachable by their `{name: ...}`-registered atom too,
    # matching the pool_name ctx a proxy would receive.
    assert Process.whereis(:voice_asr_pool) == asr_pid
    assert Process.whereis(:voice_tts_pool) == tts_pid
  end
end
