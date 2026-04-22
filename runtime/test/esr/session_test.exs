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
end
