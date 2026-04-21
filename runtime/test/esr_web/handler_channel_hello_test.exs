defmodule EsrWeb.HandlerChannelHelloTest do
  @moduledoc """
  Verifies the handler_hello IPC handshake (capabilities spec §3.1, §4.1)
  — the Python worker pushes the union of its declared permissions on
  join and the Elixir HandlerChannel registers each into
  `Esr.Permissions.Registry`.
  """
  use EsrWeb.ChannelCase, async: false

  alias Esr.Permissions.Registry

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    # Don't wipe — other suites may have populated it already; the
    # handler_hello path only needs declared?/1 to be true afterwards.
    :ok
  end

  test "handler_hello envelope registers each permission" do
    topic = "handler:test_actor/worker-hello-a"

    {:ok, _reply, socket} =
      EsrWeb.HandlerSocket
      |> socket("hw-conn", %{})
      |> subscribe_and_join(EsrWeb.HandlerChannel, topic)

    push(socket, "envelope", %{
      "kind" => "handler_hello",
      "id" => "hh-1",
      "source" => "esr://localhost/" <> topic,
      "payload" => %{"permissions" => ["test.alpha.perm", "test.beta.perm"]}
    })

    # Channel replies synchronously from handle_in; give one scheduler
    # tick so the GenServer.call into Registry completes.
    Process.sleep(20)

    assert Registry.declared?("test.alpha.perm")
    assert Registry.declared?("test.beta.perm")
  end

  test "handler_hello with empty permissions list is a no-op" do
    topic = "handler:test_actor/worker-hello-b"

    {:ok, _reply, socket} =
      EsrWeb.HandlerSocket
      |> socket("hw-conn", %{})
      |> subscribe_and_join(EsrWeb.HandlerChannel, topic)

    ref = push(socket, "envelope", %{
      "kind" => "handler_hello",
      "id" => "hh-2",
      "source" => "esr://localhost/" <> topic,
      "payload" => %{"permissions" => []}
    })

    assert_reply ref, :ok
  end

  test "handler_hello with malformed payload still replies :ok" do
    # Missing permissions key should not crash the channel — the
    # registrar defensively defaults to [] and moves on.
    topic = "handler:test_actor/worker-hello-c"

    {:ok, _reply, socket} =
      EsrWeb.HandlerSocket
      |> socket("hw-conn", %{})
      |> subscribe_and_join(EsrWeb.HandlerChannel, topic)

    ref = push(socket, "envelope", %{
      "kind" => "handler_hello",
      "id" => "hh-3",
      "source" => "esr://localhost/" <> topic,
      "payload" => %{}
    })

    assert_reply ref, :ok
  end
end
