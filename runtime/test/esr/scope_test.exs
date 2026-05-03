defmodule Esr.ScopeTest do
  use ExUnit.Case, async: false

  setup do
    # Drift from expansion doc: `Esr.Scope.Registry` is already started
    # by `Esr.Application` (P2-9 added it). Reuse the app-level Registry
    # rather than booting a redundant one.
    assert is_pid(Process.whereis(Esr.Scope.Registry))
    :ok
  end

  test "supervisor_name/1 returns a unique via tuple per session_id" do
    n1 = Esr.Scope.supervisor_name("s-1")
    n2 = Esr.Scope.supervisor_name("s-2")
    assert n1 != n2
  end

  test "supervisor_name/1 returns admin children sup for session_id == \"admin\"" do
    # Admin resolution: Scope.Admin's children supervisor (registered via application.ex).
    Application.put_env(:esr, :admin_children_sup_name, :test_admin_children)
    assert Esr.Scope.supervisor_name("admin") == :test_admin_children
  end

  test "Session.start_link starts Scope.Process + peer supervisor" do
    {:ok, sup} =
      Esr.Scope.start_link(%{
        session_id: "s-abc",
        agent_name: "cc",
        dir: "/tmp/w",
        chat_thread_key: %{chat_id: "oc", thread_id: "om"},
        metadata: %{}
      })

    children = Supervisor.which_children(sup)
    assert Enum.any?(children, fn {id, _pid, _, _} -> id == Esr.Scope.Process end)
    assert Enum.any?(children, fn {id, _pid, _, _} -> id == :peers end)
  end

  test "Scope.Process state carries session_id + agent_name + dir" do
    {:ok, _sup} =
      Esr.Scope.start_link(%{
        session_id: "s-xyz",
        agent_name: "cc",
        dir: "/tmp/w2",
        chat_thread_key: %{chat_id: "oc2", thread_id: "om2"},
        metadata: %{}
      })

    state = Esr.Scope.Process.state("s-xyz")
    assert state.session_id == "s-xyz"
    assert state.agent_name == "cc"
    assert state.dir == "/tmp/w2"
  end

  describe "Scope.Process grants (P3-3a local projection)" do
    setup do
      # Start with a clean slate so prior-test snapshots don't leak in
      # via the local projection at init time.
      :ok = Esr.Capabilities.Grants.load_snapshot(%{})

      {:ok, _sup} =
        Esr.Scope.start_link(%{
          session_id: "g-s1",
          agent_name: "cc",
          dir: "/tmp/g",
          chat_thread_key: %{chat_id: "oc", thread_id: "om"},
          metadata: %{principal_id: "p_test"}
        })

      :ok
    end

    test "Scope.Process.has?/2 denies when projection is empty" do
      refute Esr.Scope.Process.has?("g-s1", "workspace:*/msg.send")
    end

    test "Scope.Process.has?/2 agrees with Grants.has?/2 after a snapshot load" do
      # Cross-check: both sources see the same truth after the
      # broadcast propagates. The session's local map is refreshed by
      # the grants_changed broadcast, then the cross-source assertion
      # holds. Note this is an equality check, not a proof that has?/2
      # reads the global table — the performance test in
      # session_process_grants_test.exs covers that.
      :ok = Esr.Capabilities.Grants.load_snapshot(%{"p_test" => ["*"]})
      Process.sleep(50)

      assert Esr.Scope.Process.has?("g-s1", "*") ==
               Esr.Capabilities.Grants.has?("p_test", "*")
    end

    test "has? returns true after a matching grant is loaded (broadcast-refreshed)" do
      :ok = Esr.Capabilities.Grants.load_snapshot(%{"p_test" => ["*"]})

      try do
        # Give the PubSub broadcast a moment to reach the session. The
        # subsequent GenServer.call from has?/2 serialises behind the
        # handle_info grants_changed, so a small sleep avoids flakes
        # when the scheduler races the two.
        Process.sleep(50)
        assert Esr.Scope.Process.has?("g-s1", "workspace:proj/msg.send")
      after
        :ok = Esr.Capabilities.Grants.load_snapshot(%{})
      end
    end
  end
end
