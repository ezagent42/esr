defmodule Esr.Integration.N2TmuxTest do
  @moduledoc """
  P3-11 — N=2 concurrent tmux sessions, independent lifecycle.

  Spec §6 Risk D ("two of everything"). Exercises the full PR-3
  inbound chain twice in parallel and asserts three invariants:

    1. Two Sessions created via `SessionRouter.create_session/1`
       each own their own `tmux_process` GenServer with its own
       tmux session name (`esr_cc_<unique>`).

    2. Inbound text sent at Session A's `cc_process` drives only
       A's handler; inbound text at Session B's `cc_process` drives
       only B's handler. The two sessions are isolated across the
       peer chain.

    3. Tearing down Session A (`SessionRouter.end_session/1`) leaves
       Session B's `tmux_process` pid alive and B's handler still
       reachable. No cross-contamination of lifecycle.

  ## Why this test is hybrid real/synthetic

  We spawn real `tmux -C new-session` children via the production
  SessionRouter path (same spawn_args it uses in prod). That
  validates the spawn path for two peers end-to-end. However,
  **tmux's control-mode client exits shortly after init on macOS
  without a controlling TTY** (see drift notes in
  `cc_e2e_test.exs:52-62` and flake record in
  `tmux_process_test.exs:162,175`). That means the OSProcessWorker
  may have already handled `{:exit_status, 0}` by the time we race
  it — and since `TmuxProcess` is `restart: :transient`, a normal
  stop will NOT bring it back. So we do NOT assert on `tmux
  list-sessions` output (the spec's original sketch), which would
  flake on macOS. Instead we assert on:

    * the `tmux_process` GenServer pids in `SessionRegistry.refs`
      (deterministic — they live briefly regardless of tmux stdout
      race, long enough for us to snapshot them), and
    * the routing behaviour through `CCProcess.handle_upstream/2`
      which exercises the handler invocation (no tmux involvement).

  For the N=1 full `%output`→CCProcess round-trip, see
  `cc_e2e_test.exs`; for the N=2 pure-Elixir PR-2 variant (no
  tmux at all), see `n2_sessions_test.exs`.

  See spec §6 Risk D; expansion P3-11.
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
    :ok =
      Esr.TestSupport.Grants.with_grants(%{
        "ou_alice" => ["*"],
        "ou_bob" => ["*"]
      })

    :ok = Esr.SessionRegistry.load_agents(@fixture_path)

    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    on_exit(fn ->
      Application.delete_env(:esr, :handler_module_override)
    end)

    :ok
  end

  @tag timeout: 30_000
  test "two concurrent tmux-backed sessions; inbound isolation; terminating A leaves B alive",
       %{tmux_socket: tmux_sock} do
    test_pid = self()
    app_id = "n2tmux_#{System.unique_integer([:positive])}"
    admin_children_sup = Esr.AdminSession.ChildrenSupervisor

    # 1. Single FeishuAppAdapter for both sessions (they share the app
    # but differ by (chat_id, thread_id)). Matches the production
    # "one app, many threads" topology.
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

    # 2. Tag the handler so it echoes the inbound text back to the
    # test pid. Session A's cc_process and Session B's cc_process
    # share the module-level override, but the _pid_ that invokes
    # it is distinct — so we can discriminate by which cc_pid the
    # test fires text at, and by the text payload itself.
    Application.put_env(
      :esr,
      :handler_module_override,
      {:test_fun,
       fn _mod, payload, _timeout ->
         case payload["event"] do
           %{"kind" => "text", "text" => t} ->
             send(test_pid, {:handler_saw_text, t})
             {:ok, %{"turn" => 1}, []}

           _ ->
             {:ok, %{}, []}
         end
       end}
    )

    # 3. Spawn Session A (Alice / oc_a / om_a).
    {:ok, sid_a} =
      Esr.SessionRouter.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_a_#{app_id}",
        thread_id: "om_a_#{app_id}",
        app_id: app_id,
        tmux_socket: tmux_sock
      })

    # 4. Spawn Session B (Bob / oc_b / om_b) — independent (chat,thread).
    {:ok, sid_b} =
      Esr.SessionRouter.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_bob",
        chat_id: "oc_b_#{app_id}",
        thread_id: "om_b_#{app_id}",
        app_id: app_id,
        tmux_socket: tmux_sock
      })

    refute sid_a == sid_b

    # 5. Resolve both refs via SessionRegistry lookup (same path
    # production FeishuChatProxy uses).
    {:ok, ^sid_a, refs_a} =
      Esr.SessionRegistry.lookup_by_chat_thread(
        "oc_a_#{app_id}",
        app_id,
        "om_a_#{app_id}"
      )

    {:ok, ^sid_b, refs_b} =
      Esr.SessionRegistry.lookup_by_chat_thread(
        "oc_b_#{app_id}",
        app_id,
        "om_b_#{app_id}"
      )

    assert is_pid(refs_a.cc_process)
    assert is_pid(refs_b.cc_process)
    assert is_pid(refs_a.tmux_process)
    assert is_pid(refs_b.tmux_process)

    # Two independent peer chains: distinct cc_process and tmux_process
    # pids. This is the N=2 "two of everything" invariant from
    # spec §6 Risk D at the GenServer level.
    refute refs_a.cc_process == refs_b.cc_process
    refute refs_a.tmux_process == refs_b.tmux_process
    refute refs_a.feishu_chat_proxy == refs_b.feishu_chat_proxy

    # 6. Inbound-isolation leg. Send distinct texts at A's and B's
    # cc_process pids concurrently; assert the handler receives each
    # exactly once and that A's text never leaks into the B cycle
    # and vice versa.
    text_a = "text_for_alice_#{System.unique_integer([:positive])}"
    text_b = "text_for_bob_#{System.unique_integer([:positive])}"

    send(refs_a.cc_process, {:text, text_a})
    send(refs_b.cc_process, {:text, text_b})

    assert_receive {:handler_saw_text, ^text_a}, 5_000
    assert_receive {:handler_saw_text, ^text_b}, 5_000

    # No duplicate deliveries across sessions (the handler is
    # per-cc_process, but the two pids feed the same test pid — any
    # accidental double-dispatch would show up here).
    refute_receive {:handler_saw_text, ^text_a}, 200
    refute_receive {:handler_saw_text, ^text_b}, 200

    # 7. Tear-down leg. End Session A; assert A's Session supervisor
    # dies AND B's peer chain is intact.
    #
    # We capture B's peer pids BEFORE end_session runs so we can
    # monitor them — `refute_receive {:DOWN, ...}` is how we prove
    # B is untouched.
    cc_b_pid = refs_b.cc_process
    tmux_b_pid = refs_b.tmux_process
    fcp_b_pid = refs_b.feishu_chat_proxy
    mon_cc_b = Process.monitor(cc_b_pid)
    mon_tmux_b = Process.monitor(tmux_b_pid)
    mon_fcp_b = Process.monitor(fcp_b_pid)

    :ok = Esr.SessionRouter.end_session(sid_a)

    # A is gone from the registry.
    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat_thread(
               "oc_a_#{app_id}",
               app_id,
               "om_a_#{app_id}"
             )

    # B's peer pids did NOT die as collateral.
    refute_receive {:DOWN, ^mon_cc_b, :process, _, _}, 500
    refute_receive {:DOWN, ^mon_tmux_b, :process, _, _}, 0
    refute_receive {:DOWN, ^mon_fcp_b, :process, _, _}, 0
    assert Process.alive?(cc_b_pid)
    assert Process.alive?(fcp_b_pid)

    # Note on tmux_b_pid liveness: the macOS TTY-lifecycle flake
    # described in `cc_e2e_test.exs` drift notes can cause the
    # TmuxProcess OSProcessWorker to receive a `{:exit_status, 0}`
    # from its control-mode client and stop with reason `:normal`
    # before we get here. That's orthogonal to PR-3's "ending A
    # doesn't affect B" invariant. What we CAN assert deterministically
    # is that ending A did not trigger B's tmux_process to die as a
    # side-effect — i.e. if tmux_b is still alive, it stays alive;
    # if it had already died from the TTY race before end_session(A),
    # that's not caused by end_session(A). The monitor refute above
    # covers the delta-in-this-step assertion.

    # 8. B's handler is still reachable (liveness under continued load).
    text_b2 = "text_for_bob_after_A_end_#{System.unique_integer([:positive])}"
    send(cc_b_pid, {:text, text_b2})
    assert_receive {:handler_saw_text, ^text_b2}, 5_000

    # 9. Cleanup — end B too.
    :ok = Esr.SessionRouter.end_session(sid_b)

    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat_thread(
               "oc_b_#{app_id}",
               app_id,
               "om_b_#{app_id}"
             )
  end
end
