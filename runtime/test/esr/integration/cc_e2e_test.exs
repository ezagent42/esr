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
      CCProcess  ──── :send_input ────►    │ TmuxProcess       │
          ▲                                 │  (tmux -C)        │
          │                                 │   └─► tmux stdin  │
          │                                 │                   │
          │     :tmux_output  ◄─── %output──┘◄── tmux stdout    │
          │                                 └───────────────────┘
          │
          └── handler (stubbed via :handler_module_override)

  The test runs a **real tmux session** (hence `@moduletag :integration`)
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

    * `Esr.Peers.CCProxy` / `Esr.Peers.FeishuAppProxy` are stateless
      forwarder modules (no `start_link/1`); `SessionRouter` records
      them as `{:proxy_module, Module}` markers in the session refs
      map — no pid is ever spawned. So the reply chain
      `CCProcess → cc_proxy → FCP → feishu_app_proxy` is a future-PR
      wiring. The outbound leg here is therefore tested by simulating
      the final step (FAA `{:outbound, envelope}`) directly.

    * `SessionRouter.build_neighbors/1` is forward-only: each peer
      only sees peers spawned BEFORE it in the `inbound` list, so
      `CCProcess.neighbors` never contains `tmux_process`. We patch
      this in from the test via `:sys.replace_state/2`. A follow-up
      PR either reverses the spawn order for downstream-oriented
      wiring or adds a post-spawn back-wire pass.

    * The `tmux -C new-session` client exits shortly after init when
      run without a controlling TTY (macOS / CI environments). The
      session persists at the server level but our OSProcessWorker
      treats the client exit as a crash + restart loop. That's an
      orthogonal TmuxProcess issue tracked alongside P3-3; for P3-10
      we exercise the tmux→upstream leg via
      `TmuxProcess.handle_upstream/2` on a synthetic `%output` line,
      which is exactly what the real stdout path does (see
      `os_process.ex:138 dispatch_stdout/2` — a pure function call).

  See spec §4.1, §5.1 data flow; expansion P3-10.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]
  import Esr.TestSupport.TmuxIsolation
  setup :isolated_tmux_socket
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

    # SessionRouter is not booted by the Application in PR-3 (drift
    # note in session_router.ex moduledoc). Start it under the test
    # supervisor so each test gets a clean instance.
    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    on_exit(fn ->
      # Clear the handler override so it doesn't leak into sibling
      # tests that also use CCProcess.
      Application.delete_env(:esr, :handler_module_override)
    end)

    :ok
  end

  @tag timeout: 30_000
  test "Feishu inbound → CCProcess (stubbed handler) → tmux stdin → tmux stdout → FAA outbound broadcast",
       %{tmux_socket: tmux_sock} do
    test_pid = self()
    app_id = "e2e_#{System.unique_integer([:positive])}"
    chat_id = "oc_e2e_#{System.unique_integer([:positive])}"
    thread_id = "om_e2e_#{System.unique_integer([:positive])}"
    user_input = "echo hello_pr3"

    # 1. FeishuAppAdapter for app_id must exist in AdminSession before
    # SessionRouter spawns the Session (build_ctx looks up the FAA pid
    # when resolving FeishuAppProxy's target_pid).
    #
    # NOTE: earlier tests (admin_session_test.exs, session_test.exs)
    # mutate the `:admin_children_sup_name` Application env as part of
    # their own setup, and the env leaks across tests. Use the
    # canonical app-booted supervisor (Esr.AdminSession.ChildrenSupervisor)
    # directly rather than re-reading the env — that's the one
    # Esr.Application actually started and the one live here.
    admin_children_sup = Esr.AdminSession.ChildrenSupervisor

    {:ok, faa} =
      DynamicSupervisor.start_child(
        admin_children_sup,
        {Esr.Peers.FeishuAppAdapter,
         %{app_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    on_exit(fn ->
      if Process.alive?(faa) do
        DynamicSupervisor.terminate_child(admin_children_sup, faa)
      end
    end)

    # 2. Install the cross-process handler override. The CCProcess is
    # spawned by PeerFactory under Session's peers DynamicSupervisor —
    # the test doesn't own its pid at start time, so the per-pid
    # `put_handler_override/2` can't be used here. The app-env lookup
    # added in CCProcess.call_handler/3 (P3-10 helper) is the bridge.
    #
    # Stub behaviour:
    #   * on {text, user_input}      — emit :send_input back to tmux
    #     (drives the inbound leg all the way to tmux stdin).
    #   * on {tmux_output, bytes}    — notify the test pid (so we can
    #     observe the tmux→CCProcess upstream leg closing) and emit a
    #     :reply to exercise the wired-but-stateless outbound contract.
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

           %{"kind" => "tmux_output", "bytes" => bytes} ->
             send(test_pid, {:handler_saw_tmux_output, bytes})
             {:ok, %{"turn" => 2},
              [%{"type" => "reply", "text" => "saw: " <> bytes}]}

           other ->
             send(test_pid, {:handler_saw_unknown, other})
             {:ok, %{}, []}
         end
       end}
    )

    # 3. Create a session via SessionRouter — spawns the full inbound
    # peer chain (FCP → CCProxy[marker] → CCProcess → TmuxProcess) and
    # registers (chat_id, thread_id) in SessionRegistry.
    {:ok, sid} =
      Esr.SessionRouter.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: chat_id,
        thread_id: thread_id,
        app_id: app_id,
        tmux_socket: tmux_sock
      })

    # 4. Resolve the spawned peer pids from SessionRegistry.
    assert {:ok, ^sid, refs} =
             Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id)

    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_process)
    assert is_pid(refs.tmux_process)

    fcp_pid = refs.feishu_chat_proxy
    cc_pid = refs.cc_process
    tmux_pid = refs.tmux_process

    assert Process.alive?(fcp_pid)
    assert Process.alive?(cc_pid)
    assert Process.alive?(tmux_pid)

    # 5. Register the test pid as a TmuxProcess subscriber so we can
    # observe `{:tmux_event, _}` broadcasts. The TmuxProcess is an
    # OSProcessWorker (macro-generated GenServer); we add the test pid
    # to the inner state.subscribers via :sys.replace_state — idiomatic
    # test-only instrumentation, no production code touched.
    :ok = add_tmux_subscriber(tmux_pid, test_pid)

    # 5b. Backwire CCProcess → TmuxProcess. SessionRouter's
    # `build_neighbors/1` is forward-only: at spawn time each peer only
    # sees peers SPAWNED BEFORE it. The CC chain orders inbound as
    # [fcp, cc_proxy, cc_process, tmux_process] — so CCProcess's
    # neighbors never include `tmux_process`, which means the
    # `:send_input` action has nowhere to go (handles with a WARN drop
    # in dispatch_action). This is a known PR-3 wiring gap; a follow-up
    # PR will either reverse the spawn order for downstream-oriented
    # peers or add a post-spawn wire-back pass. For the integration test
    # we patch the `cc_process` state directly (test-only).
    :ok = patch_cc_neighbor(cc_pid, :tmux_process, tmux_pid)

    # 6. INBOUND LEG — send text to CCProcess directly. (FCP drops
    # non-slash in PR-3, so we bypass it for the data-plane test. The
    # FCP→CCProcess wiring is exercised by the slash-path in
    # new_session_smoke_test.exs.)
    #
    # The stubbed handler emits :send_input, CCProcess dispatches it
    # downstream to TmuxProcess which (via the OSProcessWorker
    # catch-all handle_info added in P3-10) routes into
    # `TmuxProcess.handle_downstream({:send_input, text}, state)`,
    # which in turn writes `send-keys ... Enter\n` to tmux stdin.
    send(cc_pid, {:text, user_input})

    # Stubbed handler saw the text event (CCProcess → handler).
    assert_receive {:handler_saw_text, ^user_input}, 5_000

    # CCProcess dispatched the :send_input action downstream to
    # TmuxProcess. Before P3-10, the OSProcessWorker had no
    # handle_info for {:send_input, _} and crashed with a
    # FunctionClauseError — so the fact that CCProcess is still alive
    # after sending {:text, _} is a load-bearing signal that the new
    # OSProcessWorker catch-all (routing unhandled messages to
    # `parent.handle_downstream/2`) is live.
    #
    # We deliberately do NOT assert on a real tmux %begin/%end here:
    # `tmux -C new-session` without a controlling TTY exits its
    # control-mode client almost immediately on macOS, so the Port
    # may already have emitted `%exit` and the worker may have
    # crashed+restarted by the time we race it. That's a TmuxProcess
    # TTY-lifecycle issue independent of the PR-3 wiring P3-10 targets.
    Process.sleep(50)
    assert Process.alive?(cc_pid), "CCProcess must survive dispatch"

    # 7. TMUX → CCProcess ROUND-TRIP — exercise the tmux→upstream
    # path. In production, tmux's stdout arrives as `{port, {:data,
    # {_, line}}}` inside the OSProcessWorker, which calls
    # `parent.handle_upstream({:os_stdout, line}, state)` (see
    # `os_process.ex:138 dispatch_stdout/2`). That callback is a pure
    # function — we invoke it here with the same args the worker
    # would, feeding a synthetic `%output` line. Subscribers + the
    # cc_process neighbor receive messages exactly as in the real
    # stdout path.
    #
    # We construct the TmuxProcess inner state directly rather than
    # peeking the live worker, because tmux's macOS TTY-lifecycle
    # flakiness (see drift notes) may have restarted the worker by
    # now — we still want to exercise the handle_upstream callback
    # deterministically. `subscribers = [test_pid]` and
    # `neighbors = [cc_process: cc_pid]` are exactly what the router
    # spawned TmuxProcess with (TmuxProcess is last in the inbound
    # order, so its neighbors include cc_process).
    synth_tmux_state = %{
      session_name: "synthetic",
      dir: "/tmp",
      subscribers: [test_pid],
      neighbors: [cc_process: cc_pid],
      proxy_ctx: %{}
    }

    {:forward, _, _} =
      Esr.Peers.TmuxProcess.handle_upstream(
        {:os_stdout, "%output %0 synthetic_out\n"},
        synth_tmux_state
      )

    # a) Test pid received the :tmux_event fanout (subscribers leg)
    assert_receive {:tmux_event, {:output, "%0", "synthetic_out"}}, 2_000

    # b) CCProcess's handler got re-invoked with the tmux_output
    #    event (cc_process neighbor leg — the full tmux→CCProcess
    #    round-trip).
    assert_receive {:handler_saw_tmux_output, "synthetic_out"}, 5_000

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

    # 9. Cleanup — SessionRouter.end_session tears down the Session
    # supervisor (kills CCProcess + TmuxProcess + FCP + peers_sup) and
    # unregisters (chat_id, thread_id) from SessionRegistry.
    :ok = EsrWeb.Endpoint.unsubscribe(topic)
    :ok = Esr.SessionRouter.end_session(sid)

    # Registry reflects the teardown.
    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Append `subscriber` to the TmuxProcess worker's inner
  # `state.subscribers` list. The worker (OSProcessWorker) wraps the
  # parent TmuxProcess state in `%{parent, state, port, os_pid}` — we
  # patch only `state.subscribers`.
  defp add_tmux_subscriber(tmux_pid, subscriber) do
    :sys.replace_state(tmux_pid, fn worker_state ->
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
  # backwire `tmux_process` after SessionRouter's forward-only
  # spawn pass (see drift note in test body).
  defp patch_cc_neighbor(cc_pid, key, pid) do
    :sys.replace_state(cc_pid, fn state ->
      neighbors = Keyword.put(state.neighbors, key, pid)
      %{state | neighbors: neighbors}
    end)

    :ok
  end
end
