defmodule Esr.SessionRouterTest do
  @moduledoc """
  P3-4.1 — unit tests for `Esr.SessionRouter`, the control-plane
  coordinator for Session lifecycle (spec §3.3, §6 Risk E).

  **Drift note**: the expansion doc's test snippet asserts `is_pid/1`
  on both inbound Stateful peers AND the stateless Peer.Proxy entries
  (`cc_proxy`, `feishu_app_proxy`). Per `Esr.Peer.Proxy` docs and the
  existing CCProxy/FeishuAppProxy modules, proxies are **stateless
  forwarder modules** — they have no `start_link/1` and cannot be
  spawned as pids. Tests here assert only on the Stateful peer pids
  actually present in `simple.yaml` (`feishu_chat_proxy`, `cc_process`).
  When the full CC chain lands (P3-6) with `cc_proxy` + `tmux_process`
  in the inbound list, update assertions accordingly.

  Tests do not rely on `SessionRouter` being in `Esr.Application`'s
  child tree — the router is started via `start_supervised/1` in
  `setup`, matching the user-supplied task scope (wiring into
  `application.ex` is deferred to a later subtask).
  """
  use ExUnit.Case, async: false

  alias Esr.SessionRouter

  @fixture_path Path.expand("fixtures/agents/simple.yaml", __DIR__)

  setup do
    # App-level deps exist: SessionRegistry, Session.Registry,
    # SessionsSupervisor, Grants. Start the SessionRouter under the
    # test supervisor so each test gets a clean instance.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.Session.Registry))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))

    # "*" grants everything — avoids cap-denied drops in the pipeline.
    Esr.Capabilities.Grants.load_snapshot(%{"ou_alice" => ["*"]})
    :ok = Esr.SessionRegistry.load_agents(@fixture_path)

    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    on_exit(fn ->
      Esr.Capabilities.Grants.load_snapshot(%{})

      # Tear down any Sessions dynamically started by the router so
      # subsequent tests start from a clean DynamicSupervisor.
      case Process.whereis(Esr.SessionsSupervisor) do
        nil ->
          :ok

        sup ->
          for {_, child, _, _} <- DynamicSupervisor.which_children(sup) do
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end
      end
    end)

    :ok
  end

  test "create_session_sync spawns Session supervisor + inbound Stateful peers" do
    assert {:ok, session_id} =
             SessionRouter.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_xx",
               thread_id: "om_yy",
               app_id: "cli_test"
             })

    assert is_binary(session_id)

    # Session supervisor is registered under Esr.Session.Registry.
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, session_id}}}
    assert is_pid(GenServer.whereis(via))

    # SessionRegistry records the chat-thread → session mapping and
    # the Stateful peer refs.
    assert {:ok, ^session_id, refs} =
             Esr.SessionRegistry.lookup_by_chat_thread("oc_xx", "om_yy")

    # simple.yaml inbound: feishu_chat_proxy → cc_process. Both
    # Stateful, both spawned as pids.
    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_process)
    assert Process.alive?(refs.feishu_chat_proxy)
    assert Process.alive?(refs.cc_process)
  end

  test "create_session returns {:error, :unknown_agent} for missing agent_def" do
    assert {:error, :unknown_agent} =
             SessionRouter.create_session(%{
               agent: "nonexistent",
               dir: "/tmp",
               principal_id: "ou_alice"
             })
  end

  test "end_session terminates Session supervisor + unregisters" do
    {:ok, sid} =
      SessionRouter.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_aa",
        thread_id: "om_bb",
        app_id: "cli_test"
      })

    # Precondition: lookup succeeds.
    assert {:ok, ^sid, _refs} =
             Esr.SessionRegistry.lookup_by_chat_thread("oc_aa", "om_bb")

    :ok = SessionRouter.end_session(sid)

    assert :not_found = Esr.SessionRegistry.lookup_by_chat_thread("oc_aa", "om_bb")

    # And the Session supervisor is gone.
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, sid}}}
    assert GenServer.whereis(via) == nil
  end

  test "end_session returns {:error, :unknown_session} when session does not exist" do
    assert {:error, :unknown_session} = SessionRouter.end_session("nope-sid")
  end

  # --- Risk-E drift guard (spec §6 Risk E) ---
  #
  # The handle_call catch-all only rejects control-plane-shaped calls;
  # data-plane-shaped info messages land in the handle_info catch-all
  # and are dropped with a WARN. The router MUST stay alive after
  # receiving a data-plane-shaped message.

  test "rejects unexpected GenServer.call with {:error, :not_control_plane}" do
    assert {:error, :not_control_plane} =
             GenServer.call(Esr.SessionRouter, {:inbound_event, %{"text" => "hi"}})
  end

  test "unexpected info messages are dropped (no crash)" do
    router = Process.whereis(Esr.SessionRouter)
    send(router, {:forward, "session_abc", %{"text" => "hi"}})
    # Give the router a moment to process and drop.
    _ = :sys.get_state(router)
    assert Process.alive?(router)
  end
end
