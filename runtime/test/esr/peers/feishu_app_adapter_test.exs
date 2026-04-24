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
    # No `name:` on the supervisor — a hard-coded atom collided across
    # tests when a previous run's DynamicSupervisor hadn't fully torn
    # down yet (PR-5 os_cleanup flake). Thread the pid via ctx instead.
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)
    {:ok, sup: sup}
  end

  test "start_link registers the adapter as :feishu_app_adapter_<instance_id> in AdminSessionProcess",
       %{sup: sup} do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "inst_test123", neighbors: [], proxy_ctx: %{}}}
      )

    assert Process.alive?(pid)
    {:ok, ^pid} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_inst_test123)
  end

  test "inbound envelope with chat+thread routes to the matching FeishuChatProxy via SessionRegistry",
       %{sup: sup} do
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
        sup,
        {FeishuAppAdapter, %{instance_id: "inst_test456", neighbors: [], proxy_ctx: %{}}}
      )

    # Real adapter envelope shape (see py/src/esr/ipc/envelope.py make_event).
    envelope = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_xyz",
          "thread_id" => "om_123",
          "content" => "hello"
        }
      }
    }

    send(pid, {:inbound_event, envelope})
    assert_receive {:feishu_inbound, ^envelope}, 500
  end

  test "registration key is instance_id, not Feishu-platform app_id (PR-9 T10)",
       %{sup: sup} do
    # In production the operator-chosen instance name in adapters.yaml
    # (e.g. "main_bot", "feishu_app_e2e-mock") is distinct from the
    # Feishu-platform app_id (e.g. "cli_a9563cc03d399cc9"). The Python
    # adapter_runner joins `adapter:feishu/<instance_id>`, so the Elixir
    # peer's AdminSession registration MUST be keyed on instance_id so
    # adapter_channel.forward_to_new_chain/2 can find it.
    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter,
         %{
           instance_id: "main_bot",
           app_id: "cli_a9563cc03d399cc9",
           neighbors: [],
           proxy_ctx: %{}
         }}
      )

    # Registered under instance_id.
    assert {:ok, ^pid} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_main_bot)

    # NOT registered under the Feishu-platform app_id.
    assert :error = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_cli_a9563cc03d399cc9)

    # Peer state retains the real app_id for Feishu API calls.
    assert %{app_id: "cli_a9563cc03d399cc9", instance_id: "main_bot"} = :sys.get_state(pid)
  end

  test "inbound envelope with no matching session emits :new_chat_thread event", %{sup: sup} do
    # With no SessionRegistry entry for (chat_id, thread_id),
    # FeishuAppAdapter broadcasts a :new_chat_thread event on the
    # `session_router` PubSub topic for SessionRouter to consume.
    # P3-7: topic is `session_router` (was "new_chat_thread"); tuple
    # order is `{:new_chat_thread, app_id, chat_id, thread_id, envelope}`
    # (app_id first — FeishuAppAdapter owns the wiring).
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: "inst_nomatch", neighbors: [], proxy_ctx: %{}}}
      )

    envelope = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_new",
          "thread_id" => "om_new",
          "content" => "first message"
        }
      }
    }

    send(pid, {:inbound_event, envelope})

    # Tuple's second slot is the Phoenix routing key (instance_id).
    assert_receive {:new_chat_thread, "inst_nomatch", "oc_new", "om_new", ^envelope}, 500
  end
end
