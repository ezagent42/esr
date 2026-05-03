defmodule Esr.Integration.CCE2ETest do
  @moduledoc """
  P3-10 — Full E2E integration test for the CC agent chain.

  Exercises the data-plane message flow stitched together by PR-3:

      FeishuAppAdapter (inbound)
              |
              v
      FeishuChatProxy  ────────► (drops non-slash in PR-3; see drift notes)
              |
              v                             ┌───────────────────┐
      CCProcess  ──── :send_input ────►    │ PTY peer          │
          ▲                                 │   └─► child stdin │
          │                                 │                   │
          │     stdout event ◄──────────────┘◄── child stdout   │
          │                                 └───────────────────┘
          │
          └── handler (stubbed via :handler_module_override)

  The test exercises a real OSProcess-backed peer (hence `@moduletag :integration`)
  but does NOT require any external Feishu API — the outbound leg is
  observed by subscribing to `EsrWeb.Endpoint` on the
  `adapter:feishu/<app_id>` topic and firing a simulated
  `{:outbound, envelope}` into the FeishuAppAdapter, which is how the
  production code emits frames to the Python adapter_runner socket.

  ## Known PR-3 drift from the data-plane chain
  (honest scope, not bugs this test papers over):

    * `FeishuChatProxy` drops non-slash text in PR-3 (see
      `feishu_chat_proxy.ex:54 {:drop, :non_slash_pr2, state}`). So the
      inbound path is exercised by injecting `{:text, bytes}` directly
      at the `CCProcess` pid — the boundary that the integration
      test actually _can_ observe.

    * `Esr.Entities.CCProxy` / `Esr.Entities.FeishuAppProxy` are stateless
      forwarder modules (no `start_link/1`); `Scope.Router` records
      them as `{:proxy_module, Module}` markers in the session refs
      map — no pid is ever spawned. So the reply chain
      `CCProcess → cc_proxy → FCP → feishu_app_proxy` is a future-PR
      wiring. The outbound leg here is therefore tested by simulating
      the final step (FAA `{:outbound, envelope}`) directly.

    * `Scope.Router.build_neighbors/1` is forward-only: each peer
      only sees peers spawned BEFORE it in the `inbound` list, so
      `CCProcess.neighbors` never contains `pty_process`. We patch
      this in from the test via `:sys.replace_state/2`. A follow-up
      PR either reverses the spawn order for downstream-oriented
      wiring or adds a post-spawn back-wire pass.

    * For P3-10 we exercise the child→upstream leg via
      `PtyProcess.handle_upstream/2` on a synthetic stdout line,
      which is exactly what the real stdout path does (see
      `os_process.ex:138 dispatch_stdout/2` — a pure function call).

  See spec §4.1, §5.1 data flow; expansion P3-10.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]
  setup :assert_with_grants
  setup :wipe_sessions_on_exit
  @moduletag :integration

  @fixture_path Path.expand("../fixtures/agents/simple.yaml", __DIR__)

  setup do
    # "*" grants everything so CCProxy/FeishuAppProxy cap checks never
    # short-circuit the pipeline. Prior snapshot is restored by
    # Esr.TestSupport.Grants on exit.
    :ok = Esr.TestSupport.Grants.with_principal_wildcard("ou_alice")

    :ok = Esr.SessionRegistry.load_agents(@fixture_path)

    # Scope.Router is not booted by the Application in PR-3 (drift
    # note in session_router.ex moduledoc). Start it under the test
    # supervisor so each test gets a clean instance.
    if Process.whereis(Esr.Scope.Router) == nil do
      start_supervised!(Esr.Scope.Router)
    end

    on_exit(fn ->
      # Clear the handler override so it doesn't leak into sibling
      # tests that also use CCProcess.
      Application.delete_env(:esr, :handler_module_override)
    end)

    :ok
  end

  @tag timeout: 30_000
  test "Feishu inbound → CCProcess (stubbed handler) → child stdin → child stdout → FAA outbound broadcast" do
    test_pid = self()
    app_id = "e2e_#{System.unique_integer([:positive])}"
    chat_id = "oc_e2e_#{System.unique_integer([:positive])}"
    thread_id = "om_e2e_#{System.unique_integer([:positive])}"
    user_input = "echo hello_pr3"

    # 1. FeishuAppAdapter for app_id must exist in Scope.Admin before
    # Scope.Router spawns the Session (build_ctx looks up the FAA pid
    # when resolving FeishuAppProxy's target_pid).
    #
    # NOTE: earlier tests (admin_session_test.exs, session_test.exs)
    # mutate the `:admin_children_sup_name` Application env as part of
    # their own setup, and the env leaks across tests. Use the
    # canonical app-booted supervisor (Esr.Scope.Admin.ChildrenSupervisor)
    # directly rather than re-reading the env — that's the one
    # Esr.Application actually started and the one live here.
    admin_children_sup = Esr.Scope.Admin.ChildrenSupervisor

    {:ok, faa} =
      DynamicSupervisor.start_child(
        admin_children_sup,
        {Esr.Entities.FeishuAppAdapter,
         %{app_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    on_exit(fn ->
      if Process.alive?(faa) do
        DynamicSupervisor.terminate_child(admin_children_sup, faa)
      end
    end)

    # 2. Install the cross-process handler override. The CCProcess is
    # spawned by Entity.Factory under Session's peers DynamicSupervisor —
    # the test doesn't own its pid at start time, so the per-pid
    # `put_handler_override/2` can't be used here. The app-env lookup
    # added in CCProcess.call_handler/3 (P3-10 helper) is the bridge.
    #
    # Stub behaviour:
    #   * on {text, user_input}      — emit :send_input back to the PTY peer
    #     (drives the inbound leg all the way to child stdin).

    #     observe the upstream leg closing back into CCProcess) and
    #     emit a :reply to exercise the wired-but-stateless outbound
    #     contract.
    Application.put_env(
      :esr,
      :handler_module_override,
      {:test_fun,
       fn _mod, payload, _timeout ->
         case payload["event"] do
           %{"kind" => "text", "text" => t} ->
             send(test_pid, {:handler_saw_text, t})
             {:ok, %{"turn" => 1},
              [%{"type" => "send_input", "text" => t <> "\n"}]}

           %{"kind" => "legacy_output", "bytes" => bytes} ->
             send(test_pid, {:handler_saw_legacy_output, bytes})
             {:ok, %{"turn" => 2},
              [%{"type" => "reply", "text" => "saw: " <> bytes}]}

           other ->
             send(test_pid, {:handler_saw_unknown, other})
             {:ok, %{}, []}
         end
       end}
    )

    # 3. Create a session via Scope.Router — spawns the full inbound
    # peer chain (FCP → CCProxy[marker] → CCProcess → PtyProcess) and
    # registers (chat_id, thread_id) in SessionRegistry.
    {:ok, sid} =
      Esr.Scope.Router.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: chat_id,
        thread_id: thread_id,
        app_id: app_id,
      })

    # 4. Resolve the spawned peer pids from SessionRegistry.
    assert {:ok, ^sid, refs} =
             Esr.SessionRegistry.lookup_by_chat(chat_id, app_id)

    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_process)
    assert is_pid(refs.pty_process)

    fcp_pid = refs.feishu_chat_proxy
    cc_pid = refs.cc_process
    pty_pid = refs.pty_process

    assert Process.alive?(fcp_pid)
    assert Process.alive?(cc_pid)
    assert Process.alive?(pty_pid)

    # 5. Register the test pid as a PTY-peer subscriber so we can
    # observe `{:legacy_event, _}` broadcasts. The PTY peer is an
    # OSProcessWorker (macro-generated GenServer); we add the test pid
    # to the inner state.subscribers via :sys.replace_state — idiomatic
    # test-only instrumentation, no production code touched.
    :ok = add_legacy_subscriber(pty_pid, test_pid)

    # 5b. Backwire CCProcess → PTY peer. Scope.Router's
    # `build_neighbors/1` is forward-only: at spawn time each peer only
    # sees peers SPAWNED BEFORE it. The CC chain orders inbound as
    # [fcp, cc_proxy, cc_process, pty_process] — so CCProcess's
    # neighbors never include `pty_process`, which means the
    # `:send_input` action has nowhere to go (handles with a WARN drop
    # in dispatch_action). This is a known PR-3 wiring gap; a follow-up
    # PR will either reverse the spawn order for downstream-oriented
    # peers or add a post-spawn wire-back pass. For the integration test
    # we patch the `cc_process` state directly (test-only).
    :ok = patch_cc_neighbor(cc_pid, :pty_process, pty_pid)

    # 6. INBOUND LEG — send text to CCProcess directly. (FCP drops
    # non-slash in PR-3, so we bypass it for the data-plane test. The
    # FCP→CCProcess wiring is exercised by the slash-path in
    # new_session_smoke_test.exs.)
    #
    # The stubbed handler emits :send_input, CCProcess dispatches it
    # downstream to the PTY peer which (via the OSProcessWorker
    # catch-all handle_info added in P3-10) routes into
    # `PtyProcess.handle_downstream({:send_input, text}, state)`,
    # which in turn writes the text to the child's stdin.
    send(cc_pid, {:text, user_input})

    # Stubbed handler saw the text event (CCProcess → handler).
    assert_receive {:handler_saw_text, ^user_input}, 5_000

    # CCProcess dispatched the :send_input action downstream to
    # the PTY peer. Before P3-10, the OSProcessWorker had no
    # handle_info for {:send_input, _} and crashed with a
    # FunctionClauseError — so the fact that CCProcess is still alive
    # after sending {:text, _} is a load-bearing signal that the new
    # OSProcessWorker catch-all (routing unhandled messages to
    # `parent.handle_downstream/2`) is live.
    Process.sleep(50)
    assert Process.alive?(cc_pid), "CCProcess must survive dispatch"

    # 7. PTY → CCProcess ROUND-TRIP — exercise the child→upstream
    # path. In production, the child's stdout arrives as `{port, {:data,
    # {_, line}}}` inside the OSProcessWorker, which calls
    # `parent.handle_upstream({:os_stdout, line}, state)` (see
    # `os_process.ex:138 dispatch_stdout/2`). That callback is a pure
    # function — we invoke it here with the same args the worker
    # would, feeding a synthetic stdout line. Subscribers + the
    # cc_process neighbor receive messages exactly as in the real
    # stdout path.
    #
    # We construct the PTY peer's inner state directly rather than
    # peeking the live worker so we can exercise the handle_upstream
    # callback deterministically. `subscribers = [test_pid]` and
    # `neighbors = [cc_process: cc_pid]` are exactly what the router
    # spawned the peer with (the PTY peer is last in the inbound order,
    # so its neighbors include cc_process).
    synth_legacy_state = %{
      session_name: "synthetic",
      dir: "/tmp",
      subscribers: [test_pid],
      neighbors: [cc_process: cc_pid],
      proxy_ctx: %{}
    }

    {:forward, _, _} =
      Esr.Entities.PtyProcess.handle_upstream(
        {:os_stdout, "%output %0 synthetic_out\n"},
        synth_legacy_state
      )

    # a) Test pid received the :legacy_event fanout (subscribers leg)
    assert_receive {:legacy_event, {:output, "%0", "synthetic_out"}}, 2_000

    # b) CCProcess's handler got re-invoked with the stdout event
    #    (cc_process neighbor leg — the full child→CCProcess
    #    round-trip).
    assert_receive {:handler_saw_legacy_output, "synthetic_out"}, 5_000

    # 8. OUTBOUND BROADCAST LEG — subscribe to the adapter topic and
    # simulate the FAA outbound step. In production, the reply path
    # flows CCProcess → (stateless CCProxy) → FCP → (stateless
    # FeishuAppProxy) → FAA. PR-3 leaves the two stateless hops
    # unwired (refs contain `{:proxy_module, Mod}` markers, not pids);
    # a follow-up PR will either convert them to stateful actors or
    # introduce direct dispatch helpers. For now, we verify the final
    # FAA hop works end-to-end: FAA.handle_downstream({:outbound, _})
    # triggers `EsrWeb.Endpoint.broadcast/3` on the canonical topic,
    # which is what the adapter_runner subscribes to.
    topic = "adapter:feishu/#{app_id}"
    :ok = EsrWeb.Endpoint.subscribe(topic)

    reply_text = "reply_from_session"

    outbound_envelope = %{
      "kind" => "reply",
      "args" => %{"chat_id" => chat_id, "text" => reply_text}
    }

    send(faa, {:outbound, outbound_envelope})

    # Phoenix.Socket.Broadcast struct carries topic + event + payload.
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "envelope",
                     payload: ^outbound_envelope
                   },
                   2_000

    # 9. Cleanup — Scope.Router.end_session tears down the Session
    # supervisor (kills CCProcess + PtyProcess + FCP + peers_sup) and
    # unregisters (chat_id, thread_id) from SessionRegistry.
    :ok = EsrWeb.Endpoint.unsubscribe(topic)
    :ok = Esr.Scope.Router.end_session(sid)

    # Registry reflects the teardown.
    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat(chat_id, app_id)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Append `subscriber` to the PTY peer worker's inner
  # `state.subscribers` list. The worker (OSProcessWorker) wraps the
  # parent peer state in `%{parent, state, port, os_pid}` — we patch
  # only `state.subscribers`.
  defp add_legacy_subscriber(pty_pid, subscriber) do
    :sys.replace_state(pty_pid, fn worker_state ->
      inner = worker_state.state
      existing = Map.get(inner, :subscribers, [])

      if subscriber in existing do
        worker_state
      else
        new_inner = %{inner | subscribers: [subscriber | existing]}
        %{worker_state | state: new_inner}
      end
    end)

    :ok
  end

  # Patch an additional neighbor into CCProcess's state. Used to
  # backwire `pty_process` after Scope.Router's forward-only
  # spawn pass (see drift note in test body).
  defp patch_cc_neighbor(cc_pid, key, pid) do
    :sys.replace_state(cc_pid, fn state ->
      neighbors = Keyword.put(state.neighbors, key, pid)
      %{state | neighbors: neighbors}
    end)

    :ok
  end
end
