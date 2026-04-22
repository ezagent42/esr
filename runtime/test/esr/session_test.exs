defmodule Esr.SessionTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
    :ok
  end

  test "supervisor_name/1 returns a unique via tuple per session_id" do
    n1 = Esr.Session.supervisor_name("s-1")
    n2 = Esr.Session.supervisor_name("s-2")
    assert n1 != n2
  end

  test "supervisor_name/1 returns admin children sup for session_id == \"admin\"" do
    # Admin resolution: AdminSession's children supervisor (registered via application.ex).
    Application.put_env(:esr, :admin_children_sup_name, :test_admin_children)
    assert Esr.Session.supervisor_name("admin") == :test_admin_children
  end

  test "Session.start_link starts SessionProcess + peer supervisor" do
    {:ok, sup} =
      Esr.Session.start_link(%{
        session_id: "s-abc",
        agent_name: "cc",
        dir: "/tmp/w",
        chat_thread_key: %{chat_id: "oc", thread_id: "om"},
        metadata: %{}
      })

    children = Supervisor.which_children(sup)
    assert Enum.any?(children, fn {id, _pid, _, _} -> id == Esr.SessionProcess end)
    assert Enum.any?(children, fn {id, _pid, _, _} -> id == :peers end)
  end

  test "SessionProcess state carries session_id + agent_name + dir" do
    {:ok, _sup} =
      Esr.Session.start_link(%{
        session_id: "s-xyz",
        agent_name: "cc",
        dir: "/tmp/w2",
        chat_thread_key: %{chat_id: "oc2", thread_id: "om2"},
        metadata: %{}
      })

    state = Esr.SessionProcess.state("s-xyz")
    assert state.session_id == "s-xyz"
    assert state.agent_name == "cc"
    assert state.dir == "/tmp/w2"
  end

  describe "SessionProcess grants (P2-6a scaffold)" do
    setup do
      {:ok, _sup} =
        Esr.Session.start_link(%{
          session_id: "g-s1",
          agent_name: "cc",
          dir: "/tmp/g",
          chat_thread_key: %{chat_id: "oc", thread_id: "om"},
          metadata: %{principal_id: "p_test"}
        })

      :ok
    end

    test "SessionProcess.has?/2 passes through to Esr.Capabilities.Grants.has?/2 today" do
      # With no grants loaded for principal, has? returns false.
      refute Esr.SessionProcess.has?("g-s1", "workspace:*/msg.send")
    end

    test "has? reads principal_id from metadata and calls global Grants" do
      # Same as above but illustrates the passthrough surface
      assert Esr.SessionProcess.has?("g-s1", "*") ==
               Esr.Capabilities.Grants.has?("p_test", "*")
    end

    test "has? returns true after seeding grants for principal_id" do
      # Seed the global Grants ETS — P3-3a will swap this for per-session
      # projection, but today pass-through means a write here is visible.
      prior =
        case :ets.lookup(:esr_capabilities_grants, "p_test") do
          [] -> nil
          [{_, held}] -> held
        end

      :ok = Esr.Capabilities.Grants.load_snapshot(%{"p_test" => ["*"]})

      try do
        assert Esr.SessionProcess.has?("g-s1", "workspace:proj/msg.send")
      after
        snap = if prior, do: %{"p_test" => prior}, else: %{}
        :ok = Esr.Capabilities.Grants.load_snapshot(snap)
      end
    end
  end
end
