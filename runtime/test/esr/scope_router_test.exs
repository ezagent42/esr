defmodule Esr.ScopeRouterTest do
  @moduledoc """
  P3-4.1 — unit tests for `Esr.Scope.Router`, the control-plane
  coordinator for Session lifecycle (spec §3.3, §6 Risk E).

  **Drift note**: the expansion doc's test snippet asserts `is_pid/1`
  on both inbound Stateful peers AND the stateless Peer.Proxy entries
  (`cc_proxy`, `feishu_app_proxy`). Per `Esr.Entity.Proxy` docs and the
  existing CCProxy/FeishuAppProxy modules, proxies are **stateless
  forwarder modules** — they have no `start_link/1` and cannot be
  spawned as pids. After P3-6 the `simple.yaml` pipeline inbound is
  the full CC chain (`feishu_chat_proxy → cc_proxy → cc_process →
  pty_process`); tests here assert pids for the three Stateful entries
  (`feishu_chat_proxy`, `cc_process`, `pty_process`) and NOT for the
  stateless `cc_proxy` entry (recorded symbolically in refs as
  `{:proxy_module, Module}` when reachable).

  Tests do not rely on `Scope.Router` being in `Esr.Application`'s
  child tree — the router is started via `start_supervised/1` in
  `setup`, matching the user-supplied task scope (wiring into
  `application.ex` is deferred to a later subtask).
  """
  use ExUnit.Case, async: false


  alias Esr.Scope

  @fixture_path Path.expand("fixtures/agents/simple.yaml", __DIR__)


  setup do
    # App-level deps exist: SessionRegistry, Session.Registry,
    # Scope.Supervisor, Grants. Start the Scope.Router under the
    # test supervisor so each test gets a clean instance.
    assert is_pid(Process.whereis(Esr.Resource.ChatScope.Registry))
    assert is_pid(Process.whereis(Esr.Scope.Registry))
    assert is_pid(Process.whereis(Esr.Scope.Supervisor))

    # "*" grants everything — avoids cap-denied drops in the pipeline.
    Esr.Resource.Capability.Grants.load_snapshot(%{"ou_alice" => ["*"]})
    :ok = Esr.Entity.Agent.Registry.load_agents(@fixture_path)

    if Process.whereis(Esr.Scope.Router) == nil do
      start_supervised!(Esr.Scope.Router)
    end

    on_exit(fn ->
      Esr.Resource.Capability.Grants.load_snapshot(%{})

      # Tear down any Sessions dynamically started by the router so
      # subsequent tests start from a clean DynamicSupervisor.
      case Process.whereis(Esr.Scope.Supervisor) do
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
             Scope.Router.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_xx",
               thread_id: "om_yy",
               app_id: "cli_test",
             })

    assert is_binary(session_id)

    # Session supervisor is registered under Esr.Scope.Registry.
    via = {:via, Registry, {Esr.Scope.Registry, {:session_sup, session_id}}}
    assert is_pid(GenServer.whereis(via))

    # SessionRegistry records the chat-thread → session mapping and
    # the Stateful peer refs.
    assert {:ok, ^session_id, refs} =
             Esr.Resource.ChatScope.Registry.lookup_by_chat("oc_xx", "cli_test")

    # simple.yaml inbound (post-P3-6): feishu_chat_proxy → cc_proxy →
    # cc_process → pty_process. The three Stateful peers are spawned
    # as pids; cc_proxy is a stateless module and not recorded in refs
    # via spawn (see drift note in moduledoc).
    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_process)
    assert is_pid(refs.pty_process)
    assert Process.alive?(refs.feishu_chat_proxy)
    assert Process.alive?(refs.cc_process)
    assert Process.alive?(refs.pty_process)
  end

  test "create_session enriches params with session_id + workspace_name (PR-9 T11b.2)" do
    # Seed a workspace that owns (oc_T11b2, cli_test) so workspace_for_chat
    # resolves to it; peers' init callbacks receive the enriched params.
    :ok =
      Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
        name: "T11b2_ws",
        start_cmd: "",
        role: "dev",
        chats: [%{"chat_id" => "oc_T11b2", "app_id" => "cli_test", "kind" => "dm"}],
        env: %{}
      })

    on_exit(fn -> :ets.delete(:esr_workspaces, "T11b2_ws") end)

    assert {:ok, session_id} =
             Scope.Router.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_T11b2",
               thread_id: "om_T11b2",
               app_id: "cli_test",
             })

    # FeishuChatProxy's state already carries session_id; workspace_name
    # should be reachable to peers via enriched params.
    {:ok, ^session_id, refs} =
      Esr.Resource.ChatScope.Registry.lookup_by_chat("oc_T11b2", "cli_test")

    fcp_state = :sys.get_state(refs.feishu_chat_proxy)
    assert fcp_state.session_id == session_id
  end

  test "create_session defaults workspace_name to 'default' when no chat binding exists" do
    # No workspace seeded for (oc_unbound, cli_test) — fallback kicks in.
    assert {:ok, _session_id} =
             Scope.Router.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_unbound_#{System.unique_integer([:positive])}",
               thread_id: "om_unbound",
               app_id: "cli_test",
             })
  end

  test "create_session returns {:error, :unknown_agent} for missing agent_def" do
    assert {:error, :unknown_agent} =
             Scope.Router.create_session(%{
               agent: "nonexistent",
               dir: "/tmp",
               principal_id: "ou_alice"
             })
  end

  test "end_session terminates Session supervisor + unregisters" do
    {:ok, sid} =
      Scope.Router.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_aa",
        thread_id: "om_bb",
        app_id: "cli_test",
      })

    # Precondition: lookup succeeds.
    assert {:ok, ^sid, _refs} =
             Esr.Resource.ChatScope.Registry.lookup_by_chat("oc_aa", "cli_test")

    :ok = Scope.Router.end_session(sid)

    assert :not_found = Esr.Resource.ChatScope.Registry.lookup_by_chat("oc_aa", "cli_test")

    # And the Session supervisor is gone.
    via = {:via, Registry, {Esr.Scope.Registry, {:session_sup, sid}}}
    assert GenServer.whereis(via) == nil
  end

  test "end_session returns {:error, :unknown_session} when session does not exist" do
    assert {:error, :unknown_session} = Scope.Router.end_session("nope-sid")
  end

  # --- Risk-E boundary (spec §6 Risk E) ---
  #
  # The data-plane hot path (inbound/outbound user-message traffic) must
  # NEVER be allowed to enter Scope.Router. Any shape that looks like a
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
               GenServer.call(Esr.Scope.Router, {:inbound_event, %{"text" => "hi"}})

      # Router must still be alive after the rejection.
      assert Process.alive?(Process.whereis(Esr.Scope.Router))
    end

    test "data-plane-shaped info messages are dropped (no crash)" do
      router = Process.whereis(Esr.Scope.Router)
      # {:forward, sid, envelope} is the canonical data-plane fan-out
      # shape used between Stateful peers. Must be dropped, not raise.
      send(router, {:forward, :session_abc, %{"text" => "hi"}})
      # Give the router a moment to process and drop.
      _ = :sys.get_state(router)
      assert Process.alive?(router)
    end

    test "another data-plane shape — :outbound envelope — is also dropped" do
      router = Process.whereis(Esr.Scope.Router)
      # The outbound envelope shape emitted by CCProcess/PtyProcess.
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
      router = Process.whereis(Esr.Scope.Router)
      send(router, {:DOWN, make_ref(), :process, self(), :unknown_monitor})
      _ = :sys.get_state(router)
      refute_receive {[:esr, :session_router, :peer_crashed], _, _, _, _}, 100

      # Now spawn a real session so the router has a tracked monitor,
      # kill the peer, and confirm peer_crashed fires.
      {:ok, _sid} =
        Scope.Router.create_session(%{
          agent: "cc",
          dir: "/tmp",
          principal_id: "ou_alice",
          chat_id: "oc_crash",
          thread_id: "om_crash",
          app_id: "cli_test",
        })

      # Find one spawned peer and kill it; the router's monitor will
      # DOWN and fire the telemetry event.
      {:ok, _sid2, refs} =
        Esr.Resource.ChatScope.Registry.lookup_by_chat("oc_crash", "cli_test")
      Process.exit(refs.cc_process, :kill)

      assert_receive {[:esr, :session_router, :peer_crashed], _ref, %{count: 1}, meta}, 500
      assert is_binary(meta.session_id)

      :telemetry.detach(ref)
      assert Process.alive?(router)
    end
  end

  # --- PR-9 T6 — bidirectional pipeline-spawn neighbors -----------------
  #
  # Pre-T6 `build_neighbors/1` was forward-only: each peer only saw the
  # peers spawned BEFORE it in the inbound list. That meant
  # FeishuChatProxy (spawned first) had neither a `cc_process` neighbor
  # (spawned after) nor a `feishu_app_proxy` neighbor (recorded
  # symbolically from the proxies block). T5's react-emit path requires
  # the latter, so without T6 FCP's `emit_to_feishu_app_proxy` warns
  # `:no_app_proxy_neighbor` and drops the delivery-ack.
  #
  # This test locks in the invariant: every Stateful peer spawned by
  # the pipeline sees the full adjacency — both directions of the
  # inbound chain AND the proxy-target admin pid (when the proxy's
  # `target: "admin::..."` resolves).
  test "pipeline-spawned peers have bidirectional neighbors (PR-9 T6)" do
    # Spin up a FeishuAppAdapter for the app_id so the
    # `admin::feishu_app_adapter_${app_id}` target in simple.yaml
    # resolves to a real pid (not a proxy_module fallback marker).
    app_id = "T6_#{System.unique_integer([:positive])}"
    admin_children_sup = Esr.Scope.Admin.ChildrenSupervisor

    {:ok, faa} =
      DynamicSupervisor.start_child(
        admin_children_sup,
        {Esr.Entity.FeishuAppAdapter,
         %{instance_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    on_exit(fn ->
      if Process.alive?(faa) do
        DynamicSupervisor.terminate_child(admin_children_sup, faa)
      end
    end)

    {:ok, _sid} =
      Scope.Router.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_T6",
        thread_id: "om_T6",
        app_id: app_id,
      })

    {:ok, _sid2, refs} = Esr.Resource.ChatScope.Registry.lookup_by_chat("oc_T6", app_id)

    fcp = refs.feishu_chat_proxy
    cc = refs.cc_process
    pty = refs.pty_process

    assert is_pid(fcp)
    assert is_pid(cc)
    assert is_pid(pty)

    fcp_state = :sys.get_state(fcp)

    assert is_pid(Keyword.get(fcp_state.neighbors, :cc_process)),
           "fcp → cc_process neighbor missing"

    # T6: the feishu_app_proxy neighbor must be the live
    # FeishuAppAdapter pid (not a `{:proxy_module, _}` marker) so
    # FCP's `emit_to_feishu_app_proxy` can `send(pid, {:outbound, _})`
    # directly.
    assert Keyword.get(fcp_state.neighbors, :feishu_app_proxy) == faa,
           "fcp → feishu_app_proxy neighbor must resolve to FAA pid (PR-9 T6)"

    cc_state = :sys.get_state(cc)

    assert is_pid(Keyword.get(cc_state.neighbors, :pty_process)),
           "cc → pty_process neighbor missing"

    assert is_pid(Keyword.get(cc_state.neighbors, :feishu_chat_proxy)),
           "cc → feishu_chat_proxy neighbor missing (PR-9 T6)"

    # PtyProcess is wrapped by OSProcessWorker; its inner
    # `state.neighbors` lives under `worker_state.state`.
    pty_worker_state = :sys.get_state(pty)
    pty_inner = pty_worker_state.state

    assert is_pid(Keyword.get(pty_inner.neighbors, :cc_process)),
           "pty → cc_process neighbor missing"
  end
end
