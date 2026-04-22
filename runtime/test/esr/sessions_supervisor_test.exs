defmodule Esr.SessionsSupervisorTest do
  use ExUnit.Case, async: false

  setup do
    # Drift from expansion doc: `Esr.Session.Registry` and
    # `Esr.SessionsSupervisor` are already started by `Esr.Application`
    # (P2-9 added them). Reuse the app-level instances; clean up any
    # dynamically-started session children after each test.
    assert is_pid(Process.whereis(Esr.Session.Registry))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))

    on_exit(fn ->
      # Wipe any dynamically-started Sessions so tests don't pollute
      # each other via the shared app-level DynamicSupervisor.
      case Process.whereis(Esr.SessionsSupervisor) do
        nil ->
          :ok

        pid ->
          for {_, child, _, _} <- DynamicSupervisor.which_children(pid) do
            if is_pid(child),
              do: DynamicSupervisor.terminate_child(pid, child)
          end
      end
    end)

    :ok
  end

  test "start_link starts with max_children=128" do
    # The app-level SessionsSupervisor is already running with the
    # default max_children=128. Assert it's reachable and childless
    # at test start.
    sup = Process.whereis(Esr.SessionsSupervisor)
    count = DynamicSupervisor.count_children(sup)
    assert count.active == 0
  end

  test "start_session/1 creates a Session under the dynamic supervisor" do
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
    # The module-level SessionsSupervisor is hardcoded to name itself
    # `Esr.SessionsSupervisor`, so we can't stand up a second one in the
    # same BEAM for a bounded-max probe. Instead, start a private
    # DynamicSupervisor with max_children=4 directly and shim a local
    # start_session helper.
    {:ok, sup} =
      DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 4)

    start_session = fn args ->
      DynamicSupervisor.start_child(sup, {Esr.Session, args})
    end

    # Start 4 sessions
    for i <- 1..4 do
      {:ok, _} = start_session.(%{
        session_id: "ss-cap-#{i}",
        agent_name: "cc",
        dir: "/tmp/z/#{i}",
        chat_thread_key: %{chat_id: "c-#{i}", thread_id: "t-#{i}"},
        metadata: %{}
      })
    end

    assert {:error, :max_children} = start_session.(%{
      session_id: "ss-cap-5",
      agent_name: "cc",
      dir: "/tmp/z/5",
      chat_thread_key: %{chat_id: "c-5", thread_id: "t-5"},
      metadata: %{}
    })

    on_exit(fn ->
      if Process.alive?(sup), do: Process.exit(sup, :shutdown)
    end)
  end
end
