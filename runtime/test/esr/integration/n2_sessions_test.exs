defmodule Esr.Integration.N2SessionsTest do
  @moduledoc """
  P2-12: N=2 concurrent user Sessions with no cross-contamination.

  Exercises the full PR-2 inbound path end-to-end:

      FeishuAppAdapter(app_A)   FeishuAppAdapter(app_B)
              |                          |
              +--SessionRegistry.lookup_by_chat_thread/3--+
              |                          |
        FeishuChatProxy(A)         FeishuChatProxy(B)

  Two real `Esr.Scope` subtrees are started under the app-level
  `Esr.Scope.Supervisor`. Each registers a distinct
  `(chat_id, thread_id)` key against its own `feishu_chat_proxy` pid
  (a test-owned receiver). Concurrent `{:inbound_event, envelope}`
  messages are dispatched to each FeishuAppAdapter; the test asserts:

    1. Session A receives only A's envelope, never B's.
    2. Session B receives only B's envelope, never A's.
    3. Terminating Session A does NOT disturb Session B — it keeps
       receiving its own inbound frames.

  Covers spec §6 Risk D (N>1 session safety).

  Intentionally NOT tagged `:integration`: the whole graph is pure
  Elixir + supervisor tree, no OS processes, so it runs in the
  default `mix test` profile.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_app_singletons: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]

  alias Esr.Entity.FeishuAppAdapter

  setup :assert_app_singletons
  setup :wipe_sessions_on_exit

  setup do
    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../fixtures/agents/multi_app.yaml", __DIR__)
      )

    {:ok, sup_a} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, sup_b} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      for sid <- ["n2-session-A", "n2-session-B"] do
        Esr.SessionRegistry.unregister_session(sid)
      end

      if Process.alive?(sup_a), do: Process.exit(sup_a, :shutdown)
      if Process.alive?(sup_b), do: Process.exit(sup_b, :shutdown)
    end)

    {:ok, %{fab_sup_a: sup_a, fab_sup_b: sup_b}}
  end

  test "two FeishuAppAdapters + two Sessions: inbound frames do not cross-contaminate",
       %{fab_sup_a: sup_a, fab_sup_b: sup_b} do
    test_pid = self()

    # Two test-owned proxy pids, each tagged so we can distinguish which
    # session received a frame. They forward `:feishu_inbound` to the
    # test process with the tag prepended.
    proxy_a =
      spawn_link(fn -> relay_loop(:a, test_pid) end)

    proxy_b =
      spawn_link(fn -> relay_loop(:b, test_pid) end)

    # Start two real Sessions under Esr.Scope.Supervisor.
    {:ok, session_sup_a} =
      Esr.Scope.Supervisor.start_session(%{
        session_id: "n2-session-A",
        agent_name: "cc",
        dir: "/tmp/n2/A",
        chat_thread_key: %{chat_id: "oc_a", app_id: "app_A", thread_id: "om_a"},
        metadata: %{principal_id: "ou_a"}
      })

    {:ok, session_sup_b} =
      Esr.Scope.Supervisor.start_session(%{
        session_id: "n2-session-B",
        agent_name: "cc",
        dir: "/tmp/n2/B",
        chat_thread_key: %{chat_id: "oc_b", app_id: "app_B", thread_id: "om_b"},
        metadata: %{principal_id: "ou_b"}
      })

    assert Process.alive?(session_sup_a)
    assert Process.alive?(session_sup_b)

    # Register each session in SessionRegistry with a distinct
    # (chat_id, app_id, thread_id) key. The `feishu_chat_proxy` ref
    # points at our test-owned relay pid so we can observe dispatch
    # decisions. PR-A T1: app_id mirrors the FAA instance_id below so
    # the legacy fallback path resolves correctly.
    :ok =
      Esr.SessionRegistry.register_session(
        "n2-session-A",
        %{chat_id: "oc_a", app_id: "app_A", thread_id: "om_a"},
        %{feishu_chat_proxy: proxy_a}
      )

    :ok =
      Esr.SessionRegistry.register_session(
        "n2-session-B",
        %{chat_id: "oc_b", app_id: "app_B", thread_id: "om_b"},
        %{feishu_chat_proxy: proxy_b}
      )

    # Start one FeishuAppAdapter per app_id under a per-test
    # DynamicSupervisor (the app boot does not start adapters for
    # arbitrary app_ids; these are test-local).
    {:ok, _fab_a} =
      DynamicSupervisor.start_child(
        sup_a,
        {FeishuAppAdapter, %{instance_id: "app_A", neighbors: [], proxy_ctx: %{}}}
      )

    {:ok, _fab_b} =
      DynamicSupervisor.start_child(
        sup_b,
        {FeishuAppAdapter, %{instance_id: "app_B", neighbors: [], proxy_ctx: %{}}}
      )

    # Resolve the adapters via Scope.Admin.Process (same path
    # FeishuAppProxy uses in production).
    {:ok, fab_a} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_app_A)
    {:ok, fab_b} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_app_B)

    env_a = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_a", "thread_id" => "om_a", "content" => "A-hello"}
      }
    }

    env_b = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_b", "thread_id" => "om_b", "content" => "B-hello"}
      }
    }

    # Fire concurrently.
    send(fab_a, {:inbound_event, env_a})
    send(fab_b, {:inbound_event, env_b})

    # Assert session A got A-hello, never B-hello.
    assert_receive {:relay, :a, %{"payload" => %{"args" => %{"content" => "A-hello"}}}}, 1_000
    refute_receive {:relay, :a, %{"payload" => %{"args" => %{"content" => "B-hello"}}}}, 200

    # Assert session B got B-hello, never A-hello.
    assert_receive {:relay, :b, %{"payload" => %{"args" => %{"content" => "B-hello"}}}}, 1_000
    refute_receive {:relay, :b, %{"payload" => %{"args" => %{"content" => "A-hello"}}}}, 200

    # --- Session termination isolation (Risk D, second limb) ---
    #
    # Killing Session A's whole subtree must not affect Session B:
    #   a) B's Session supervisor stays alive
    #   b) B's FeishuChatProxy relay still routes inbound frames
    ref_b = Process.monitor(session_sup_b)
    :ok = Esr.Scope.Supervisor.stop_session(session_sup_a)
    refute Process.alive?(session_sup_a)

    # Ensure B is still alive and we did NOT receive a DOWN for it.
    refute_receive {:DOWN, ^ref_b, :process, _, _}, 100
    assert Process.alive?(session_sup_b)

    # Unregister A so the adapter's lookup returns :not_found for A's
    # (chat_id, thread_id). A second A-inbound must NOT resurrect the
    # dead relay or leak to B.
    :ok = Esr.SessionRegistry.unregister_session("n2-session-A")

    env_b2 = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_b",
          "thread_id" => "om_b",
          "content" => "B-after-A-dead"
        }
      }
    }

    send(fab_b, {:inbound_event, env_b2})

    assert_receive {:relay, :b,
                    %{"payload" => %{"args" => %{"content" => "B-after-A-dead"}}}},
                   1_000
    refute_receive {:relay, :a, _}, 200
  end

  # Tiny relay that tags and forwards every `:feishu_inbound` frame to
  # the test process so assert_receive can discriminate which session
  # actually received it.
  defp relay_loop(tag, test_pid) do
    receive do
      {:feishu_inbound, envelope} ->
        send(test_pid, {:relay, tag, envelope})
        relay_loop(tag, test_pid)

      _other ->
        relay_loop(tag, test_pid)
    end
  end
end
