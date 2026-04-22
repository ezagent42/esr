defmodule Esr.Peers.FeishuAppAdapterTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppAdapter

  setup do
    # Drift from expansion doc: both `Esr.SessionRegistry` (via 4d) and
    # `Esr.AdminSessionProcess` (via P2-9's AdminSession) are now started
    # at app boot, so a redundant `start_supervised!` would crash with
    # :already_started. Reuse the app-level processes.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :fab_test_sup)

    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)
    :ok
  end

  test "start_link registers the adapter as :feishu_app_adapter_<app_id> in AdminSessionProcess" do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        :fab_test_sup,
        {FeishuAppAdapter, %{app_id: "cli_app_test123", neighbors: [], proxy_ctx: %{}}}
      )

    assert Process.alive?(pid)
    {:ok, ^pid} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_cli_app_test123)
  end

  test "inbound envelope with chat+thread routes to the matching FeishuChatProxy via SessionRegistry" do
    # Arrange: register a fake session with a test-owned "proxy pid"
    test_pid = self()

    :ok =
      Esr.SessionRegistry.register_session(
        "session-abc",
        %{chat_id: "oc_xyz", thread_id: "om_123"},
        %{feishu_chat_proxy: test_pid}
      )

    {:ok, pid} =
      DynamicSupervisor.start_child(
        :fab_test_sup,
        {FeishuAppAdapter, %{app_id: "cli_app_test456", neighbors: [], proxy_ctx: %{}}}
      )

    envelope = %{
      "payload" => %{
        "event_type" => "im.message.receive_v1",
        "chat_id" => "oc_xyz",
        "thread_id" => "om_123",
        "text" => "hello"
      }
    }

    send(pid, {:inbound_event, envelope})
    assert_receive {:feishu_inbound, ^envelope}, 500
  end

  test "inbound envelope with no matching session emits :new_chat_thread event" do
    # With no SessionRegistry entry for (chat_id, thread_id), FeishuAppAdapter
    # broadcasts a :new_chat_thread event on PubSub for SessionRouter to consume
    # (SessionRouter itself is PR-3; in PR-2 we assert the broadcast happens).
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "new_chat_thread")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        :fab_test_sup,
        {FeishuAppAdapter, %{app_id: "cli_app_nomatch", neighbors: [], proxy_ctx: %{}}}
      )

    envelope = %{
      "payload" => %{
        "event_type" => "im.message.receive_v1",
        "chat_id" => "oc_new",
        "thread_id" => "om_new",
        "text" => "first message"
      }
    }

    send(pid, {:inbound_event, envelope})

    assert_receive {:new_chat_thread, "oc_new", "om_new", "cli_app_nomatch", ^envelope}, 500
  end
end
