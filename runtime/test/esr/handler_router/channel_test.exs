defmodule EsrWeb.HandlerChannelTest do
  @moduledoc """
  PRD 01 F12 — HandlerChannel correlates ``handler_reply`` frames back
  to waiting ``HandlerRouter.call`` callers via Phoenix.PubSub on topic
  ``handler_reply:<id>``.
  """

  use EsrWeb.ChannelCase, async: false

  test "joining a handler topic succeeds" do
    topic = "handler:noop/worker-#{System.unique_integer([:positive])}"

    assert {:ok, _reply, _socket} =
             EsrWeb.HandlerSocket
             |> socket("handler-conn", %{})
             |> subscribe_and_join(EsrWeb.HandlerChannel, topic)
  end

  test "join rejects topics that don't match handler:<module>/<worker_id>" do
    assert {:error, %{reason: "invalid topic"}} =
             EsrWeb.HandlerSocket
             |> socket("handler-conn", %{})
             |> subscribe_and_join(EsrWeb.HandlerChannel, "handler:bogus")
  end

  test "handler_reply push broadcasts on handler_reply:<id> topic" do
    call_id = "hc-test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "handler_reply:" <> call_id)

    topic = "handler:noop/worker-1"
    {:ok, _reply, socket} =
      EsrWeb.HandlerSocket
      |> socket("handler-conn", %{})
      |> subscribe_and_join(EsrWeb.HandlerChannel, topic)

    envelope = %{
      "id" => call_id,
      "type" => "handler_reply",
      "source" => "esr://localhost/handler/noop.on_msg",
      "payload" => %{"new_state" => %{"counter" => 1}, "actions" => []}
    }

    push(socket, "handler_reply", envelope)
    assert_receive {:handler_reply, ^envelope}, 500
  end

  test "handler_reply without id is rejected" do
    topic = "handler:noop/worker-2"
    {:ok, _reply, socket} =
      EsrWeb.HandlerSocket
      |> socket("handler-conn", %{})
      |> subscribe_and_join(EsrWeb.HandlerChannel, topic)

    ref = push(socket, "handler_reply", %{"payload" => %{}})
    assert_reply ref, :error, %{reason: _}
  end

  test "unhandled event returns an error reply" do
    topic = "handler:noop/worker-3"
    {:ok, _reply, socket} =
      EsrWeb.HandlerSocket
      |> socket("handler-conn", %{})
      |> subscribe_and_join(EsrWeb.HandlerChannel, topic)

    ref = push(socket, "bogus_event", %{})
    assert_reply ref, :error, %{reason: _}
  end
end
