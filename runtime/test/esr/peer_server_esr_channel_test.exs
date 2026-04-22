defmodule Esr.PeerServerEsrChannelTest do
  use ExUnit.Case, async: false

  alias Esr.SessionSocketRegistry

  setup do
    sid = "sess-ch-#{System.unique_integer([:positive])}"
    parent = self()

    ws_pid =
      spawn(fn ->
        receive do
          {:push_envelope, env} -> send(parent, {:pushed, env})
        end
      end)

    SessionSocketRegistry.register(sid,
      ws_pid: ws_pid,
      chat_ids: ["oc_x"],
      app_ids: ["cli_x"],
      workspace: "w"
    )

    %{sid: sid}
  end

  test "Emit adapter=esr-channel routes via SessionSocketRegistry + fires emit.dispatched telemetry",
       %{sid: sid} do
    :telemetry.attach(
      "test-esr-ch",
      [:esr, :emit, :dispatched],
      fn _event, _meas, meta, pid -> send(pid, {:telemetry, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("test-esr-ch") end)

    action = %{
      "type" => "emit",
      "adapter" => "esr-channel",
      "action" => "notify_session",
      "args" => %{
        "session_id" => sid,
        "source" => "feishu",
        "chat_id" => "oc_x",
        "content" => "hi"
      }
    }

    state = %Esr.PeerServer{
      actor_id: "thread:#{sid}",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    _new_state = Esr.PeerServer.dispatch_action_for_test(action, state)

    assert_receive {:pushed, %{"kind" => "notification", "content" => "hi"}}, 500

    assert_receive {:telemetry,
                    %{adapter: "esr-channel", action: "notify_session", session_id: ^sid}},
                   500
  end
end
