defmodule EsrWeb.ChannelIntegrationTest do
  use EsrWeb.ChannelCase, async: false

  alias Esr.AdapterSocketRegistry
  alias Esr.TestSupport.AuthContext

  setup do
    # Post-P2-16: emit_topic_for/2 dropped its AdapterHub.Registry
    # lookup — it now returns the deterministic "adapter:<name>/<actor>"
    # shape, so tests just subscribe to that exact topic (no registry
    # bind/unbind dance required).
    #
    # CAP-4 Lane B: tool_invoke checks the caller's grants. The MCP
    # channel defaults to ESR_BOOTSTRAP_PRINCIPAL_ID when no
    # session_register lands — grant that principal admin so existing
    # round-trip assertions keep passing.
    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "test_admin")
    AuthContext.load_admin("test_admin")

    on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)
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

    # Post-P2-16: emit_topic_for("feishu", actor_id) deterministically
    # returns "adapter:feishu/<actor_id>" (no more HubRegistry fan-out).
    # Subscribe to exactly that topic so emit_and_track's broadcast
    # lands on our mailbox as a %Phoenix.Socket.Broadcast{}.
    adapter_topic = "adapter:feishu/" <> actor_id
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

  test "notify_session pushes an inbound envelope via AdapterSocketRegistry" do
    sid = "notify-sid-#{System.unique_integer([:positive])}"

    # Joining registers the session in AdapterSocketRegistry with ws_pid = channel pid.
    {:ok, _, _ch_socket} =
      EsrWeb.ChannelSocket
      |> socket("mcp-client-2", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/" <> sid)

    # AdapterSocketRegistry.notify_session sends {:push_envelope, envelope} to
    # the ChannelChannel process, which pushes it back over the socket.
    :ok =
      AdapterSocketRegistry.notify_session(sid, %{
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
