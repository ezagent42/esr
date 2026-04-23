defmodule EsrWeb.AdapterChannelPrincipalTest do
  @moduledoc """
  Capabilities spec §6.2/§6.3 (CAP-3 wiring) — inbound adapter events
  MUST carry ``principal_id``. The AdapterChannel rejects envelopes
  without one (catches mis-migrated adapters) and propagates both
  ``principal_id`` + ``workspace_name`` onto the envelope that flows
  into the peer chain.

  Post-P2-17: the legacy `Esr.AdapterHub.Registry` → PeerServer routing
  was removed (P2-16) and the `USE_NEW_PEER_CHAIN` feature flag was
  removed in P2-17 (migration complete; no current caller activates it).
  These tests exercise the sole path:
  `adapter:feishu/<app_id>` topics route through
  `AdminSessionProcess.admin_peer(:feishu_app_adapter_<app_id>)` → pid
  which `send`s the envelope as `{:inbound_event, envelope}`. The test
  registers the caller pid as a stand-in for that adapter, so
  assertions ride on the caller's mailbox directly (no Dynamic-
  Supervisor churn, no ordering races vs. `FeishuAppAdapterTest`).

  Rejection happens at `handle_in("event", ...)` BEFORE the forward,
  so rejection assertions do not depend on the downstream chain.
  """

  use EsrWeb.ChannelCase, async: false

  setup do
    app_id = "princ_app_#{System.unique_integer([:positive])}"
    topic = "adapter:feishu/#{app_id}"
    sym = String.to_atom("feishu_app_adapter_#{app_id}")

    # Register the caller pid as a stand-in FeishuAppAdapter — the
    # AdminSessionProcess monitors the pid and auto-clears the entry
    # on exit, so no on_exit cleanup is needed.
    :ok = Esr.AdminSessionProcess.register_admin_peer(sym, self())

    %{topic: topic, app_id: app_id}
  end

  test "event with principal_id + workspace_name forwards both onto the envelope",
       %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    envelope = %{
      "id" => "e-princ-1",
      "type" => "event",
      "source" => "esr://localhost/adapter/feishu-shared",
      "principal_id" => "ou_alice",
      "workspace_name" => "proj-a",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_1"}
      }
    }

    push(socket, "event", envelope)

    assert_receive {:inbound_event, received}, 500
    assert received["principal_id"] == "ou_alice"
    assert received["workspace_name"] == "proj-a"
  end

  test "event with nil workspace_name is still accepted (chat-not-in-any-workspace case)",
       %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    envelope = %{
      "id" => "e-princ-2",
      "principal_id" => "ou_alice",
      "workspace_name" => nil,
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    push(socket, "event", envelope)

    assert_receive {:inbound_event, received}, 500
    assert received["principal_id"] == "ou_alice"
    assert received["workspace_name"] == nil
  end

  test "event WITHOUT principal_id is rejected with explicit error", %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    ref =
      push(socket, "event", %{
        "id" => "e-no-princ",
        "payload" => %{"event_type" => "msg_received", "args" => %{}}
      })

    assert_reply ref, :error, %{reason: reason}
    assert reason =~ "principal_id required"
    # The stand-in pid must NOT have received anything
    refute_receive {:inbound_event, _}, 100
  end

  test "event with empty-string principal_id is rejected", %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    ref =
      push(socket, "event", %{
        "id" => "e-empty-princ",
        "principal_id" => "",
        "payload" => %{}
      })

    assert_reply ref, :error, %{reason: reason}
    assert reason =~ "principal_id required"
  end

  test "'envelope' with kind=event also enforces principal_id", %{topic: topic} do
    # The envelope-wrapped path delegates to handle_in("event", ...) so
    # the same rejection must fire.
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    ref =
      push(socket, "envelope", %{
        "kind" => "event",
        "id" => "e-env-no-princ",
        "payload" => %{}
      })

    assert_reply ref, :error, %{reason: reason}
    assert reason =~ "principal_id required"
  end
end
