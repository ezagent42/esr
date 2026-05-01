defmodule Esr.Integration.NewChatThreadSignalTest do
  @moduledoc """
  P3-7 — end-to-end test of the `FeishuAppAdapter → SessionRouter`
  signal bridge for new (chat_id, thread_id) pairs.

  Flow under test:

    1. FeishuAppAdapter receives `{:inbound_event, envelope}`.
    2. `SessionRegistry.lookup_by_chat_thread/3` returns `:not_found`.
    3. FAA broadcasts `{:new_chat_thread, app_id, chat_id, thread_id,
       envelope}` on the `session_router` PubSub topic.
    4. SessionRouter receives the broadcast and calls
       `do_create/1` (auto-spawn).
    5. A new session exists in `SessionRegistry.lookup_by_chat_thread/3`.

  P3-7 promotes this path from **log-only** (PR-3 interim) to
  **auto-create**. The spec expansion originally called for log-only
  drops; the user brief for PR-3 explicitly scopes this to auto-create.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_app_singletons: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]

  setup :assert_app_singletons
  setup :wipe_sessions_on_exit

  @moduletag :integration

  @fixture_path Path.expand("../fixtures/agents/simple.yaml", __DIR__)

  setup do
    :ok = Esr.TestSupport.Grants.with_principal_wildcard("ou_alice")
    :ok = Esr.SessionRegistry.load_agents(@fixture_path)

    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :p3_7_sup)

    on_exit(fn ->
      if Process.alive?(sup), do: Process.exit(sup, :shutdown)
    end)

    :ok
  end

  test "FAA lookup-miss → :new_chat_thread → SessionRouter auto-creates session" do
    app_id = "pr3_auto_#{System.unique_integer([:positive])}"

    {:ok, faa} =
      DynamicSupervisor.start_child(
        :p3_7_sup,
        {Esr.Peers.FeishuAppAdapter,
         %{app_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:esr, :session_router, :new_chat_thread_auto_created]
      ])

    chat_id = "oc_auto_#{System.unique_integer([:positive])}"
    thread_id = "om_auto_#{System.unique_integer([:positive])}"

    envelope = %{
      "payload" => %{
        "event_type" => "im.message.receive_v1",
        "chat_id" => chat_id,
        "thread_id" => thread_id,
        "sender" => %{"open_id" => "ou_alice"},
        "text" => "hello"
      }
    }

    send(faa, {:inbound_event, envelope})

    # Auto-create telemetry fires with the new session_id.
    assert_receive {[:esr, :session_router, :new_chat_thread_auto_created], _ref,
                    %{count: 1}, meta},
                   2_000

    assert meta.app_id == app_id
    assert meta.chat_id == chat_id
    assert meta.thread_id == thread_id
    assert is_binary(meta.session_id)

    # SessionRegistry now knows about the (chat_id, app_id, thread_id) mapping.
    assert {:ok, sid, refs} =
             Esr.SessionRegistry.lookup_by_chat(chat_id, app_id)

    assert sid == meta.session_id
    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_process)

    :telemetry.detach(ref)
  end
end
