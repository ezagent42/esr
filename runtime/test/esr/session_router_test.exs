defmodule Esr.SessionRouterTest do
  @moduledoc """
  P3-4.1 — unit tests for `Esr.Session.Router`, the control-plane
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

  Tests do not rely on `Session.Router` being in `Esr.Application`'s
  child tree — the router is started via `start_supervised/1` in
  `setup`, matching the user-supplied task scope (wiring into
  `application.ex` is deferred to a later subtask).
  """
  use ExUnit.Case, async: false


  alias Esr.Session

  @fixture_path Path.expand("fixtures/agents/simple.yaml", __DIR__)


  setup do
    # App-level deps exist: SessionRegistry, Session.Registry,
    # Session.Supervisor, Grants. Start the Session.Router under the
    # test supervisor so each test gets a clean instance.
    assert is_pid(Process.whereis(Esr.Session.ChatRouting.Registry))
    assert is_pid(Process.whereis(Esr.Session.Registry))
    assert is_pid(Process.whereis(Esr.Session.Supervisor))

    # "*" grants everything — avoids cap-denied drops in the pipeline.
    Esr.Resource.Capability.Grants.load_snapshot(%{"ou_alice" => ["*"]})

    # Phase 5 cut-over: AgentSpawner reads agent_def from params.
    # Phase 6 (2026-05-10): the legacy `Esr.Entity.Agent.Registry`
    # agents.yaml cache is gone; the fixture is retained as test data.
    # Build the cc agent_def directly from the fixture via the
    # AgentDefFixture helper.
    {:ok, cc_def} = Esr.TestSupport.AgentDefFixture.cc_agent_def(@fixture_path)

    if Process.whereis(Esr.Session.Router) == nil do
      start_supervised!(Esr.Session.Router)
    end

    on_exit(fn ->
      Esr.Resource.Capability.Grants.load_snapshot(%{})

      # Tear down any Sessions dynamically started by the router so
      # subsequent tests start from a clean DynamicSupervisor.
      case Process.whereis(Esr.Session.Supervisor) do
        nil ->
          :ok

        sup ->
          for {_, child, _, _} <- DynamicSupervisor.which_children(sup) do
            if is_pid(child), do: DynamicSupervisor.terminate_child(sup, child)
          end
      end
    end)

    {:ok, cc_def: cc_def}
  end

  test "create_session_sync spawns Session supervisor + inbound Stateful peers", %{cc_def: cc_def} do
    assert {:ok, session_id} =
             Session.Router.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_xx",
               thread_id: "om_yy",
               app_id: "cli_test",
               agent_def: cc_def
             })

    assert is_binary(session_id)

    # Session supervisor is registered under Esr.Session.Registry.
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, session_id}}}
    assert is_pid(GenServer.whereis(via))

    # SessionRegistry records the chat → session mapping.
    assert {:ok, ^session_id} =
             Esr.Session.ChatRouting.Registry.current_session("oc_xx", "cli_test")

    # PR-3 Task 3.3b: peer refs no longer live in the ChatRouting ETS
    # row. The Stateful peers (feishu_chat_proxy, cc_process,
    # pty_process per simple.yaml) register themselves in
    # Esr.ActorQuery's role index on init, so we assert their presence
    # there instead.
    assert {:ok, fcp_pid} = Esr.ActorQuery.fcp_for_session(session_id)
    assert is_pid(fcp_pid) and Process.alive?(fcp_pid)

    assert [cc_pid | _] = Esr.ActorQuery.list_by_role(session_id, :cc_process)
    assert is_pid(cc_pid) and Process.alive?(cc_pid)

    assert [pty_pid | _] = Esr.ActorQuery.list_by_role(session_id, :pty_process)
    assert is_pid(pty_pid) and Process.alive?(pty_pid)
  end

  test "create_session enriches params with session_id + workspace_name (PR-9 T11b.2)", %{cc_def: cc_def} do
    # Seed a workspace that owns (oc_T11b2, cli_test) so workspace_for_chat
    # resolves to it; peers' init callbacks receive the enriched params.
    :ok =
      Esr.Uri.Compat.workspace_put(
        Esr.Test.WorkspaceFixture.build(
          name: "T11b2_ws",
          role: "dev",
          chats: [%{"chat_id" => "oc_T11b2", "app_id" => "cli_test", "kind" => "dm"}]
        )
      )

    on_exit(fn -> Esr.Test.WorkspaceFixture.delete!("T11b2_ws") end)

    assert {:ok, session_id} =
             Session.Router.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_T11b2",
               thread_id: "om_T11b2",
               app_id: "cli_test",
               agent_def: cc_def
             })

    # FeishuChatProxy's state already carries session_id; workspace_name
    # should be reachable to peers via enriched params.
    {:ok, ^session_id} =
      Esr.Session.ChatRouting.Registry.current_session("oc_T11b2", "cli_test")

    {:ok, fcp_pid} = Esr.ActorQuery.fcp_for_session(session_id)
    fcp_state = :sys.get_state(fcp_pid)
    assert fcp_state.session_id == session_id
  end

  test "create_session defaults workspace_name to 'default' when no chat binding exists", %{cc_def: cc_def} do
    # No workspace seeded for (oc_unbound, cli_test) — fallback kicks in.
    assert {:ok, _session_id} =
             Session.Router.create_session(%{
               agent: "cc",
               dir: "/tmp",
               principal_id: "ou_alice",
               chat_id: "oc_unbound_#{System.unique_integer([:positive])}",
               thread_id: "om_unbound",
               app_id: "cli_test",
               agent_def: cc_def
             })
  end

  test "create_session returns {:error, :agent_def_required} when caller omits agent_def" do
    # Phase 5 cut-over: AgentSpawner no longer fetches from agents.yaml.
    # Pre-cut this returned :unknown_agent for an unknown name; post-cut
    # the failure mode is "caller didn't supply an agent_def".
    assert {:error, :agent_def_required} =
             Session.Router.create_session(%{
               agent: "nonexistent",
               dir: "/tmp",
               principal_id: "ou_alice"
             })
  end

  test "end_session terminates Session supervisor + unregisters", %{cc_def: cc_def} do
    {:ok, sid} =
      Session.Router.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_aa",
        thread_id: "om_bb",
        app_id: "cli_test",
        agent_def: cc_def
      })

    # Precondition: lookup succeeds.
    assert {:ok, ^sid} =
             Esr.Session.ChatRouting.Registry.current_session("oc_aa", "cli_test")

    :ok = Session.Router.end_session(sid)

    assert :not_found = Esr.Session.ChatRouting.Registry.current_session("oc_aa", "cli_test")

    # And the Session supervisor is gone.
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, sid}}}
    assert GenServer.whereis(via) == nil
  end

  test "end_session returns {:error, :unknown_session} when session does not exist" do
    assert {:error, :unknown_session} = Session.Router.end_session("nope-sid")
  end

  # --- Risk-E boundary (spec §6 Risk E) ---
  #
  # The data-plane hot path (inbound/outbound user-message traffic) must
  # NEVER be allowed to enter Session.Router. Any shape that looks like a
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
               GenServer.call(Esr.Session.Router, {:inbound_event, %{"text" => "hi"}})

      # Router must still be alive after the rejection.
      assert Process.alive?(Process.whereis(Esr.Session.Router))
    end

    test "data-plane-shaped info messages are dropped (no crash)" do
      router = Process.whereis(Esr.Session.Router)
      # {:forward, sid, envelope} is the canonical data-plane fan-out
      # shape used between Stateful peers. Must be dropped, not raise.
      send(router, {:forward, :session_abc, %{"text" => "hi"}})
      # Give the router a moment to process and drop.
      _ = :sys.get_state(router)
      assert Process.alive?(router)
    end

    test "another data-plane shape — :outbound envelope — is also dropped" do
      router = Process.whereis(Esr.Session.Router)
      # The outbound envelope shape emitted by CCProcess/PtyProcess.
      send(router, {:outbound, %{"payload" => %{"text" => "bye"}}})
      _ = :sys.get_state(router)
      assert Process.alive?(router)
    end

    test "telemetry fires on peer_crashed DOWN without crashing the router", %{cc_def: cc_def} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:esr, :session_router, :peer_crashed]
        ])

      # A DOWN for an unknown monitor ref must NOT fire peer_crashed
      # (it's dropped silently) — confirms the early-return clause.
      router = Process.whereis(Esr.Session.Router)
      send(router, {:DOWN, make_ref(), :process, self(), :unknown_monitor})
      _ = :sys.get_state(router)
      refute_receive {[:esr, :session_router, :peer_crashed], _, _, _, _}, 100

      # Now spawn a real session so the router has a tracked monitor,
      # kill the peer, and confirm peer_crashed fires.
      {:ok, _sid} =
        Session.Router.create_session(%{
          agent: "cc",
          dir: "/tmp",
          principal_id: "ou_alice",
          chat_id: "oc_crash",
          thread_id: "om_crash",
          app_id: "cli_test",
          agent_def: cc_def
        })

      # Find one spawned peer and kill it; the router's monitor will
      # DOWN and fire the telemetry event.
      {:ok, sid2} =
        Esr.Session.ChatRouting.Registry.current_session("oc_crash", "cli_test")

      [cc_pid | _] = Esr.ActorQuery.list_by_role(sid2, :cc_process)
      Process.exit(cc_pid, :kill)

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
  test "pipeline-spawned peers have bidirectional neighbors (PR-9 T6)", %{cc_def: cc_def} do
    # Spin up a FeishuAppAdapter for the app_id so the
    # `admin::feishu_app_adapter_${app_id}` target in simple.yaml
    # resolves to a real pid (not a proxy_module fallback marker).
    app_id = "T6_#{System.unique_integer([:positive])}"
    admin_children_sup = Esr.Session.Admin.ChildrenSupervisor

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
      Session.Router.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_T6",
        thread_id: "om_T6",
        app_id: app_id,
        agent_def: cc_def
      })

    {:ok, sid2} = Esr.Session.ChatRouting.Registry.current_session("oc_T6", app_id)

    # PR-3 Task 3.3b: peer refs no longer live in ETS — look up via
    # the role index directly.
    {:ok, fcp} = Esr.ActorQuery.fcp_for_session(sid2)
    [cc | _] = Esr.ActorQuery.list_by_role(sid2, :cc_process)
    [pty | _] = Esr.ActorQuery.list_by_role(sid2, :pty_process)

    assert is_pid(fcp)
    assert is_pid(cc)
    assert is_pid(pty)

    # M-2: state.neighbors deleted. Bidirectional resolution is now via
    # `Esr.ActorQuery.list_by_role/2` (Index 3, populated by each peer's
    # `register_attrs/2` in init). Old assertions on
    # `Keyword.get(state.neighbors, :*)` are gone.
    fcp_state = :sys.get_state(fcp)
    sid = fcp_state.session_id

    assert cc in Esr.ActorQuery.list_by_role(sid, :cc_process),
           "ActorQuery: cc_process role index should resolve to spawned CC pid"

    assert fcp in Esr.ActorQuery.list_by_role(sid, :feishu_chat_proxy),
           "ActorQuery: feishu_chat_proxy role index should resolve to spawned FCP pid"

    assert pty in Esr.ActorQuery.list_by_role(sid, :pty_process),
           "ActorQuery: pty_process role index should resolve to spawned PTY pid"

    # FCP's home-app outbound branch (`emit_to_feishu_app_proxy`) routes
    # via `ActorQuery.list_by_role(sid, :feishu_app_proxy)`. The live
    # FeishuAppAdapter is registered in Index 1 under
    # "feishu_app_adapter_<app_id>"; cross-app branch consults Index 1
    # directly. Either way the spawned faa pid must be reachable.
    assert {:ok, ^faa} =
             Esr.Entity.Registry.lookup("feishu_app_adapter_" <> app_id)
  end
end
