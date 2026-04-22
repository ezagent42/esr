defmodule Esr.Peers.FeishuChatProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuChatProxy

  setup do
    # Drift from expansion doc: `Esr.SessionRegistry` is already started by
    # `Esr.Application` (see application.ex "4d. Session registry"), so a
    # redundant `start_supervised!` would crash with :already_started.
    # Same drift that feishu_app_adapter_test.exs already called out.
    # `Esr.AdminSessionProcess` is NOT yet in the application tree (that
    # lands with P2-9), so we start it locally here.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    start_supervised!({Esr.AdminSessionProcess, []})
    :ok
  end

  test "slash-prefix messages route to slash_handler via AdminSessionProcess" do
    test_pid = self()
    :ok = Esr.AdminSessionProcess.register_admin_peer(:slash_handler, test_pid)

    {:ok, peer} =
      GenServer.start_link(FeishuChatProxy, %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "om_1",
        neighbors: [],
        proxy_ctx: %{}
      })

    send(peer, {:feishu_inbound, %{
      "payload" => %{"text" => "/new-session --agent cc --dir /tmp/w"}
    }})

    assert_receive {:slash_cmd, _env, reply_to}, 500
    assert reply_to == peer
  end

  test "non-slash messages are dropped + logged (PR-2 scope)" do
    import ExUnit.CaptureLog

    {:ok, peer} =
      GenServer.start_link(FeishuChatProxy, %{
        session_id: "s2",
        chat_id: "oc_y",
        thread_id: "om_2",
        neighbors: [],
        proxy_ctx: %{}
      })

    # Test-only drift from expansion doc: config/test.exs sets the
    # primary Logger level to :warning, so capture_log alone cannot
    # see info-level output. Temporarily lower the level inside the
    # test and restore on exit. The implementation itself is unchanged
    # (still Logger.info as spec'd).
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      capture_log(fn ->
        send(peer, {:feishu_inbound, %{"payload" => %{"text" => "hello, not a slash"}}})
        Process.sleep(50)
      end)

    assert log =~ "feishu_chat_proxy: non-slash dropped (PR-3 wires downstream)"
  end
end
