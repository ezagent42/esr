defmodule EsrWeb.AdapterChannelPrincipalTest do
  @moduledoc """
  Capabilities spec §6.2/§6.3 (CAP-3 wiring) — inbound adapter events
  MUST carry ``principal_id``. The AdapterChannel rejects envelopes
  without one (catches mis-migrated adapters) and propagates both
  ``principal_id`` + ``workspace_name`` into the
  ``{:inbound_event, envelope}`` tuple forwarded to the bound
  PeerServer.
  """

  use EsrWeb.ChannelCase, async: false

  alias Esr.AdapterHub.Registry, as: HubRegistry

  setup do
    actor_id = "feishu_app_proxy.princ-#{System.unique_integer([:positive])}"
    topic = "adapter:feishu-shared/princ-#{System.unique_integer([:positive])}"

    {:ok, _} = Registry.register(Esr.PeerRegistry, actor_id, nil)
    :ok = HubRegistry.bind(topic, actor_id)

    on_exit(fn -> HubRegistry.unbind(topic) end)

    %{topic: topic, actor_id: actor_id}
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
    # PeerServer must NOT have received anything
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
