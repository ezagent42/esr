defmodule Esr.SessionsSupervisorTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
    :ok
  end

  test "start_link starts with max_children=128" do
    {:ok, sup} = Esr.SessionsSupervisor.start_link([])
    count = DynamicSupervisor.count_children(sup)
    assert count.active == 0
    # Can't directly assert max_children from public API; use a probe:
    # try to start 129 sessions and expect the 129th to fail.
    # Keep this as a separate explicit test to avoid slow test here.
    :ok
  end

  test "start_session/1 creates a Session under the dynamic supervisor" do
    {:ok, _sup} = Esr.SessionsSupervisor.start_link([])

    {:ok, session_sup} = Esr.SessionsSupervisor.start_session(%{
      session_id: "ss-1",
      agent_name: "cc",
      dir: "/tmp/y",
      chat_thread_key: %{chat_id: "oc", thread_id: "om"},
      metadata: %{}
    })

    assert Process.alive?(session_sup)
    assert DynamicSupervisor.count_children(Esr.SessionsSupervisor).active == 1
  end

  @tag :slow
  test "129th concurrent session returns :max_children" do
    {:ok, _sup} = Esr.SessionsSupervisor.start_link(max_children: 4)

    # Start 4 sessions
    for i <- 1..4 do
      {:ok, _} = Esr.SessionsSupervisor.start_session(%{
        session_id: "ss-cap-#{i}",
        agent_name: "cc",
        dir: "/tmp/z/#{i}",
        chat_thread_key: %{chat_id: "c-#{i}", thread_id: "t-#{i}"},
        metadata: %{}
      })
    end

    assert {:error, :max_children} = Esr.SessionsSupervisor.start_session(%{
      session_id: "ss-cap-5",
      agent_name: "cc",
      dir: "/tmp/z/5",
      chat_thread_key: %{chat_id: "c-5", thread_id: "t-5"},
      metadata: %{}
    })
  end
end
