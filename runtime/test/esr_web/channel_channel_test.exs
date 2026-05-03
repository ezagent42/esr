defmodule EsrWeb.ChannelChannelTest do
  use EsrWeb.ChannelCase, async: false

  alias Esr.AdapterSocketRegistry

  @topic "cli:channel/test-sid"

  test "join registers the session as online" do
    {:ok, _reply, _socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, @topic)

    {:ok, row} = AdapterSocketRegistry.lookup("test-sid")
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

    {:ok, row} = AdapterSocketRegistry.lookup("regtest")
    assert row.workspace == "esr-dev"
    assert row.chat_ids == ["oc_x"]
    assert row.app_ids == ["cli_x"]
  end

  describe "duplicate-join rejection (PR-9 T11b.4a)" do
    test "second join on same session_id returns {:error, already_joined}" do
      topic = "cli:channel/dup-#{System.unique_integer([:positive])}"

      {:ok, _reply, _socket} =
        EsrWeb.ChannelSocket
        |> socket("ch-first", %{})
        |> subscribe_and_join(EsrWeb.ChannelChannel, topic)

      assert {:error, %{reason: "already_joined"}} =
               EsrWeb.ChannelSocket
               |> socket("ch-second", %{})
               |> subscribe_and_join(EsrWeb.ChannelChannel, topic)
    end

    test "re-join after first client's terminate succeeds" do
      Process.flag(:trap_exit, true)
      topic = "cli:channel/rejoin-#{System.unique_integer([:positive])}"

      {:ok, _reply, first} =
        EsrWeb.ChannelSocket
        |> socket("ch-first", %{})
        |> subscribe_and_join(EsrWeb.ChannelChannel, topic)

      close(first)
      Process.sleep(50)

      # Registry row is now offline; a fresh client must be allowed in.
      assert {:ok, _reply, _socket} =
               EsrWeb.ChannelSocket
               |> socket("ch-second", %{})
               |> subscribe_and_join(EsrWeb.ChannelChannel, topic)
    end
  end

  test "terminate marks session offline" do
    Process.flag(:trap_exit, true)

    {:ok, _reply, socket} =
      EsrWeb.ChannelSocket
      |> socket("ch-conn", %{})
      |> subscribe_and_join(EsrWeb.ChannelChannel, "cli:channel/termtest")

    close(socket)
    Process.sleep(50)

    {:ok, row} = AdapterSocketRegistry.lookup("termtest")
    assert row.status == :offline
  end
end
