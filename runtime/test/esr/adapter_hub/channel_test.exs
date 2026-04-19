defmodule EsrWeb.AdapterChannelTest do
  @moduledoc """
  PRD 01 F09 — AdapterChannel routes inbound Phoenix events to the
  PeerServer bound via AdapterHub.Registry.
  """

  use EsrWeb.ChannelCase, async: false

  alias Esr.AdapterHub.Registry, as: HubRegistry

  setup do
    # A fresh binding topic each test; use the caller pid as the
    # "PeerServer" so assert_receive can verify the routing.
    actor_id = "feishu_app_proxy.test-#{System.unique_integer([:positive])}"
    topic = "adapter:feishu-shared/inst-#{System.unique_integer([:positive])}"

    # Register self() under the actor_id in PeerRegistry
    {:ok, _} = Registry.register(Esr.PeerRegistry, actor_id, nil)
    :ok = HubRegistry.bind(topic, actor_id)

    on_exit(fn ->
      HubRegistry.unbind(topic)
      # Registry.register for self() is cleaned up automatically on exit
    end)

    %{topic: topic, actor_id: actor_id}
  end

  test "joining the adapter topic succeeds", %{topic: topic} do
    assert {:ok, _reply, _socket} =
             EsrWeb.AdapterSocket
             |> socket("adapter-conn", %{})
             |> subscribe_and_join(EsrWeb.AdapterChannel, topic)
  end

  test "'event' push routes to bound PeerServer as {:inbound_event, _}",
       %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    envelope = %{
      "id" => "e-abc",
      "ts" => "2026-04-19T10:00:00Z",
      "type" => "event",
      "source" => "esr://localhost/adapter/feishu-shared",
      "payload" => %{"event_type" => "msg_received", "args" => %{"chat_id" => "oc_1"}}
    }

    push(socket, "event", envelope)
    assert_receive {:inbound_event, received}, 500
    assert received["id"] == "e-abc"
    assert received["payload"]["event_type"] == "msg_received"
  end

  test "'directive_ack' push routes to bound PeerServer as {:directive_ack, _}",
       %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    ack = %{
      "id" => "d-abc",
      "type" => "directive_ack",
      "source" => "esr://localhost/adapter/feishu-shared",
      "payload" => %{"ok" => true, "result" => %{"message_id" => "m_1"}}
    }

    push(socket, "directive_ack", ack)
    assert_receive {:directive_ack, received}, 500
    assert received["id"] == "d-abc"
  end

  test "'envelope' with kind=event routes like a bare 'event' push",
       %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    envelope = %{
      "kind" => "event",
      "id" => "e-env",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    push(socket, "envelope", envelope)
    assert_receive {:inbound_event, received}, 500
    assert received["id"] == "e-env"
  end

  test "'envelope' with kind=directive_ack routes like a bare 'directive_ack' push",
       %{topic: topic} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "directive_ack:d-env")

    ack = %{
      "kind" => "directive_ack",
      "id" => "d-env",
      "payload" => %{"ok" => true, "result" => %{"session_name" => "alpha"}}
    }

    push(socket, "envelope", ack)
    assert_receive {:directive_ack, received}, 500
    assert received["id"] == "d-env"
  end

  test "join succeeds even without a binding (late binding race resolved at forward/2)" do
    # Python adapter workers join before Topology.Instantiator creates
    # the HubRegistry binding; otherwise the broadcast race is lost. Join
    # must succeed; routing errors surface on the first push.
    topic = "adapter:nothing/bound-here"
    assert {:ok, _reply, socket} =
             EsrWeb.AdapterSocket
             |> socket("adapter-conn", %{})
             |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    # A push against an unbound topic replies :error — no PeerServer to
    # route to, so the forward/2 helper yields the "no binding" reason.
    ref = push(socket, "event", %{"id" => "e-no-bind", "payload" => %{}})
    assert_reply ref, :error, %{reason: "no binding"}
  end

  test "event push when PeerServer has died replies with error",
       %{topic: topic, actor_id: actor_id} do
    {:ok, _reply, socket} =
      EsrWeb.AdapterSocket
      |> socket("adapter-conn", %{})
      |> subscribe_and_join(EsrWeb.AdapterChannel, topic)

    # Unregister the binding to simulate a dead PeerServer.
    Registry.unregister(Esr.PeerRegistry, actor_id)

    ref = push(socket, "event", %{"id" => "e-orphan", "payload" => %{}})
    assert_reply ref, :error, %{reason: _}
  end
end
