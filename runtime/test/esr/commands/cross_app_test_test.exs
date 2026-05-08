defmodule Esr.Commands.CrossAppTestTest do
  @moduledoc """
  PR-A T9: e2e test-harness command synthesizes a tool_invoke into a
  session's FCP peer, bypassing claude. The unit test stands up a fake
  FCP that registers under `thread:<sid>` and answers the synthesized
  invocation with a canned `{:push_envelope, ...}`. We exercise:

    1. Happy path — fake FCP echoes back ok:true; command returns it.
    2. Missing args — execute/1 rejects with invalid_args.
    3. No registered peer — command returns no_session_peer.
    4. Reply timeout — fake FCP eats the message; command times out.
  """
  use ExUnit.Case, async: false
  alias Esr.Commands.CrossAppTest

  defp register_fake_fcp(session_id, parent, mode \\ :echo) do
    spawn_link(fn ->
      Esr.Entity.Registry.register("thread:" <> session_id, self())
      send(parent, {:fcp_ready, self()})
      fake_fcp_loop(parent, mode)
    end)

    receive do
      {:fcp_ready, pid} -> pid
    after
      500 -> flunk("fake FCP did not register in 500ms")
    end
  end

  defp fake_fcp_loop(parent, :echo) do
    receive do
      {:tool_invoke, req_id, tool, args, channel_pid, principal_id} ->
        send(parent, {:fcp_received, req_id, tool, args, principal_id})

        # Mirror what FCP does on a successful cross-app dispatch:
        # push back a tool_result envelope to channel_pid.
        send(channel_pid, {
          :push_envelope,
          %{
            "kind" => "tool_result",
            "req_id" => req_id,
            "ok" => true,
            "data" => %{"echoed" => args}
          }
        })

        fake_fcp_loop(parent, :echo)
    end
  end

  defp fake_fcp_loop(parent, :silent) do
    # Drop messages on the floor — exercises the command's timeout.
    receive do
      msg ->
        send(parent, {:silently_dropped, msg})
        fake_fcp_loop(parent, :silent)
    end
  end

  test "happy path forwards the synthesized tool_invoke and returns the FCP envelope" do
    sid = "S_CROSS_OK_" <> rand_suffix()
    register_fake_fcp(sid, self())

    {:ok, envelope} =
      CrossAppTest.execute(%{
        "args" => %{
          "session_id" => sid,
          "chat_id" => "oc_target",
          "app_id" => "feishu_target",
          "text" => "ping",
          "principal_id" => "ou_admin"
        }
      })

    assert envelope["ok"] == true
    assert is_binary(envelope["req_id"])
    assert envelope["data"]["echoed"]["chat_id"] == "oc_target"
    assert envelope["data"]["echoed"]["app_id"] == "feishu_target"

    # And FCP did receive the synthesized tool_invoke with the right
    # tool name + principal_id.
    assert_receive {:fcp_received, _, "reply", _, "ou_admin"}, 500
  end

  test "missing args returns invalid_args error without invoking anyone" do
    assert {:error, %{"type" => "invalid_args"}} =
             CrossAppTest.execute(%{"args" => %{"session_id" => "S_X"}})
  end

  test "no peer registered for session_id returns no_session_peer" do
    assert {:error, %{"type" => "no_session_peer", "session_id" => "S_NOPE"}} =
             CrossAppTest.execute(%{
               "args" => %{
                 "session_id" => "S_NOPE",
                 "chat_id" => "oc_x",
                 "app_id" => "f_x",
                 "text" => "x",
                 "principal_id" => "ou_x"
               }
             })
  end

  test "FCP unresponsive within timeout returns timeout error" do
    sid = "S_CROSS_TIMEOUT_" <> rand_suffix()
    register_fake_fcp(sid, self(), :silent)

    # The default timeout is 5s; override to a faster value via the
    # module attribute by relying on the silent loop swallowing the
    # message. We can't easily override the timeout without exposing
    # it, so this test just confirms the timeout shape — actual run
    # waits the full 5s. Tag it slow if needed.
    {:error, %{"type" => "timeout"}} =
      CrossAppTest.execute(%{
        "args" => %{
          "session_id" => sid,
          "chat_id" => "oc_t",
          "app_id" => "f_t",
          "text" => "t",
          "principal_id" => "ou_t"
        }
      })
  end

  defp rand_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
