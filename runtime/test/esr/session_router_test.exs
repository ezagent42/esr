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

  # --- Risk-E boundary (spec §6 Risk E) ---
  #
  # The data-plane hot path (inbound/outbound user-message traffic) must
  # NEVER be allowed to enter SessionRouter. Any shape that looks like a
  # data-plane envelope must be rejected (call) or dropped (cast/info)
  # with a WARN, and MUST NEVER crash the router. If a data-plane shape
  # ever makes it in, the router's supervisor-restart cascade would
  # masquerade the mistake as a transient blip; the boundary test below
  # is the last line of defence before that happens.
  #
  # P3-5 adds these explicit Risk-E tests (spec §6 Risk E) on top of
  # the pre-existing drift guards. Together they exercise:
  #   1. data-plane-shaped GenServer.call  → {:error, :not_control_plane}
  #   2. data-plane-shaped info message    → drop + WARN, router alive
  #   3. peer-crashed DOWN (a legit control-plane info shape that rides
  #      the same handle_info/2 module) fires telemetry without crash.

  describe "Risk E — data-plane boundary (spec §6)" do
    test "rejects data-plane-shaped GenServer.call with {:error, :not_control_plane}" do
      # An {:inbound_event, envelope} tuple is the canonical data-plane
      # shape used by Peer.Stateful.handle_upstream/2. It must never be
      # accepted as a control-plane call.
      assert {:error, :not_control_plane} =
               GenServer.call(Esr.SessionRouter, {:inbound_event, %{"text" => "hi"}})

      # Router must still be alive after the rejection.
      assert Process.alive?(Process.whereis(Esr.SessionRouter))
    end

    test "data-plane-shaped info messages are dropped (no crash)" do
      router = Process.whereis(Esr.SessionRouter)
      # {:forward, sid, envelope} is the canonical data-plane fan-out
      # shape used between Stateful peers. Must be dropped, not raise.
      send(router, {:forward, :session_abc, %{"text" => "hi"}})
      # Give the router a moment to process and drop.
      _ = :sys.get_state(router)
      assert Process.alive?(router)
    end

    test "another data-plane shape — :outbound envelope — is also dropped" do
      router = Process.whereis(Esr.SessionRouter)
      # The outbound envelope shape emitted by CCProcess/TmuxProcess.
      send(router, {:outbound, %{"payload" => %{"text" => "bye"}}})
      _ = :sys.get_state(router)
      assert Process.alive?(router)
    end

    test "telemetry fires on peer_crashed DOWN without crashing the router" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:esr, :session_router, :peer_crashed]
        ])

      # A DOWN for an unknown monitor ref must NOT fire peer_crashed
      # (it's dropped silently) — confirms the early-return clause.
      router = Process.whereis(Esr.SessionRouter)
      send(router, {:DOWN, make_ref(), :process, self(), :unknown_monitor})
      _ = :sys.get_state(router)
      refute_receive {[:esr, :session_router, :peer_crashed], _, _, _, _}, 100

      # Now spawn a real session so the router has a tracked monitor,
      # kill the peer, and confirm peer_crashed fires.
      {:ok, _sid} =
        SessionRouter.create_session(%{
          agent: "cc",
          dir: "/tmp",
          principal_id: "ou_alice",
          chat_id: "oc_crash",
          thread_id: "om_crash",
          app_id: "cli_test"
        })

      # Find one spawned peer and kill it; the router's monitor will
      # DOWN and fire the telemetry event.
      {:ok, _sid2, refs} = Esr.SessionRegistry.lookup_by_chat_thread("oc_crash", "om_crash")
      Process.exit(refs.cc_process, :kill)

      assert_receive {[:esr, :session_router, :peer_crashed], _ref, %{count: 1}, meta}, 500
      assert is_binary(meta.session_id)

      :telemetry.detach(ref)
      assert Process.alive?(router)
    end
  end
end
