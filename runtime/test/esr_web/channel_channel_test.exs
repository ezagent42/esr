defmodule EsrWeb.ChannelChannelTest do
  use EsrWeb.ChannelCase, async: false

  alias Esr.SessionSocketRegistry

  @topic "cli:channel/test-sid"

  test "join registers the session as online" do
    {:ok, _reply, _socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, @topic)

    {:ok, row} = SessionSocketRegistry.lookup("test-sid")
    assert row.status == :online
  end

  test "envelope with kind=session_register updates chat_ids" do
    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/regtest")

    push(socket, "envelope",
      %{"kind" => "session_register",
        "session_id" => "regtest",
        "workspace" => "esr-dev",
        "chats" => [%{"chat_id" => "oc_x", "app_id" => "cli_x", "kind" => "dm"}]})

    # give the channel process a tick to apply
    Process.sleep(50)

    {:ok, row} = SessionSocketRegistry.lookup("regtest")
    assert row.workspace == "esr-dev"
    assert row.chat_ids == ["oc_x"]
    assert row.app_ids == ["cli_x"]
  end

  test "terminate marks session offline" do
    Process.flag(:trap_exit, true)

    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/termtest")

    close(socket)
    Process.sleep(50)

    {:ok, row} = SessionSocketRegistry.lookup("termtest")
    assert row.status == :offline
  end
end
