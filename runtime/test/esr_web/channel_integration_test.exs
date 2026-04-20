defmodule EsrWeb.ChannelIntegrationTest do
  use EsrWeb.ChannelCase, async: false

  alias Esr.SessionRegistry

  setup do
    # Guarantee emit_topic_for("feishu", ...) resolves to OUR test topic by
    # clearing any feishu-adapter bindings left by earlier tests in the
    # shared HubRegistry ETS.
    for {topic, _actor_id} <- Esr.AdapterHub.Registry.list() do
      if String.starts_with?(topic, "adapter:feishu/") do
        :ok = Esr.AdapterHub.Registry.unbind(topic)
      end
    end

    :ok
  end

  test "tool_invoke reply round-trips through feishu fake adapter" do
    sid = "int-sid-#{System.unique_integer([:positive])}"
    actor_id = "thread:" <> sid

    # Start a real PeerServer under the test supervisor so it registers
    # in Esr.PeerRegistry under the actor_id that ChannelChannel looks up.
    {:ok, _pid} =
      start_supervised(
        {Esr.PeerServer,
         [
           actor_id: actor_id,
           actor_type: "feishu_thread_proxy",
           handler_module: "feishu_thread",
           initial_state: %{"chat_id" => "oc_int"}
         ]}
      )

    # Bind a feishu adapter topic so emit_topic_for("feishu", ...) resolves
    # to a real Phoenix topic we can subscribe to.
    unique_suffix = Integer.to_string(System.unique_integer([:positive]))
    adapter_topic = "adapter:feishu/feishu-app:cli_int_" <> unique_suffix
    :ok = Esr.AdapterHub.Registry.bind(adapter_topic, actor_id)

    # Subscribe the test process to that adapter topic via Endpoint so we
    # receive %Phoenix.Socket.Broadcast{} when emit_and_track broadcasts.
    EsrWeb.Endpoint.subscribe(adapter_topic)

    # Join the MCP side — ChannelChannel.join registers the session.
    {:ok, _, ch_socket} =
      EsrWeb.ChannelSocket
      |> socket("mcp-client", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    # Fire the tool_invoke envelope.
    req_id = "req-int-1"

    push(ch_socket, "envelope", %{
      "kind" => "tool_invoke",
      "req_id" => req_id,
      "tool" => "reply",
      "args" => %{"chat_id" => "oc_int", "text" => "hello"}
    })

    # The emit_and_track in PeerServer broadcasts to the adapter topic.
    # Receive the directive envelope and extract the id.
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 2_000
    directive_id = env["id"]
    assert is_binary(directive_id)

    # Simulate the fake adapter replying with a directive_ack via PubSub
    # (same channel AdapterChannel.handle_in("directive_ack", ...) uses).
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "directive_ack:" <> directive_id,
      {:directive_ack,
       %{
         "id" => directive_id,
         "payload" => %{
           "ok" => true,
           "result" => %{"message_id" => "om_int"}
         }
       }}
    )

    # PeerServer sends {:tool_result, req_id, result} to the ChannelChannel
    # process, which pushes an "envelope" back over the MCP socket.
    assert_receive %Phoenix.Socket.Message{
                     event: "envelope",
                     payload: %{
                       "kind" => "tool_result",
                       "req_id" => ^req_id,
                       "ok" => true
                     }
                   },
                   3_000
  end

  test "notify_session pushes an inbound envelope via SessionRegistry" do
    sid = "notify-sid-#{System.unique_integer([:positive])}"

    # Joining registers the session in SessionRegistry with ws_pid = channel pid.
    {:ok, _, _ch_socket} =
      EsrWeb.ChannelSocket
      |> socket("mcp-client-2", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    # SessionRegistry.notify_session sends {:push_envelope, envelope} to
    # the ChannelChannel process, which pushes it back over the socket.
    :ok =
      SessionRegistry.notify_session(sid, %{
        "kind" => "notification",
        "content" => "direct-notify-" <> sid
      })

    assert_receive %Phoenix.Socket.Message{
                     event: "envelope",
                     payload: %{"kind" => "notification", "content" => content}
                   },
                   2_000

    assert String.ends_with?(content, sid)
  end
end
