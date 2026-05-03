defmodule EsrWeb.AdapterChannelNewChainTest do
  @moduledoc """
  P2-11 — For `adapter:feishu/<app_id>` topics, EsrWeb.AdapterChannel
  routes inbound envelopes to the registered `Esr.Entity.FeishuAppAdapter`
  for that app_id (looked up via `Esr.Scope.Admin.Process.admin_peer/1`
  under the symbolic name `:feishu_app_adapter_<app_id>`).

  Post-P2-17: the `USE_NEW_PEER_CHAIN` feature flag was removed during
  the peer chain migration (P2-16/P2-17); the new chain is the sole path.
  """
  use ExUnit.Case, async: false

  alias Esr.Entity.FeishuAppAdapter

  setup do
    # Drift from expansion: both `Esr.SessionRegistry` and
    # `Esr.Scope.Admin.Process` are started at app boot (see the
    # existing `FeishuAppAdapterTest` setup for the same note).
    # A redundant `start_supervised!({Esr.Scope.Admin.Process, []})`
    # crashes with `:already_started`, so reuse the app-level pid.
    assert is_pid(Process.whereis(Esr.Scope.Admin.Process))

    {:ok, _sup} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: :p2_11_test_sup)

    {:ok, _fab_pid} =
      DynamicSupervisor.start_child(
        :p2_11_test_sup,
        {FeishuAppAdapter, %{instance_id: "cli_app_p211", neighbors: [], proxy_ctx: %{}}}
      )

    on_exit(fn ->
      case Process.whereis(:p2_11_test_sup) do
        nil -> :ok
        pid -> Process.exit(pid, :shutdown)
      end
    end)

    :ok
  end

  test "adapter_channel forwards {:inbound_event, envelope} to FeishuAppAdapter when flag on" do
    {:ok, _fab_pid} =
      Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_cli_app_p211)

    # Subscribe BEFORE triggering the forward so the broadcast emitted
    # inside FeishuAppAdapter.handle_upstream (no session matches →
    # :new_chat_thread) can't race ahead of us. P3-7: topic renamed to
    # `session_router` + tuple order `{app_id, chat_id, thread_id, ...}`.
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")

    envelope = %{
      "principal_id" => "p1",
      "workspace_name" => "w1",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{
          "chat_id" => "oc_test",
          "thread_id" => "om_test",
          "content" => "hi"
        }
      }
    }

    :ok = EsrWeb.AdapterChannel.forward_to_new_chain("adapter:feishu/cli_app_p211", envelope)

    assert_receive {:new_chat_thread, "cli_app_p211", "oc_test", "om_test", ^envelope}, 500
  end

  test "forward_to_new_chain returns :error when no FeishuAppAdapter is registered for the app_id" do
    assert :error =
             EsrWeb.AdapterChannel.forward_to_new_chain(
               "adapter:feishu/cli_app_missing",
               %{"payload" => %{}}
             )
  end
end
