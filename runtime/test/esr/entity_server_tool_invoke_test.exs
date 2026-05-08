defmodule Esr.EntityServerToolInvokeTest do
  use ExUnit.Case, async: false

  alias Esr.Entity

  test "invoke_tool_for_test/3 returns ok for valid reply args" do
    peer_state = %Entity.Server{
      actor_id: "thread:sess-1",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{"chat_id" => "oc_x"}
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "reply", %{
      "chat_id" => "oc_x",
      "text" => "hi"
    })

    assert result == %{"ok" => true}
  end

  test "invoke_tool_for_test/3 returns error for missing reply args" do
    peer_state = %Entity.Server{
      actor_id: "thread:sess-1",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "reply", %{"chat_id" => "oc_x"})

    assert result["ok"] == false
    assert result["error"]["type"] == "invalid_args"
  end

  test "invoke_tool_for_test/3 rejects unknown tool" do
    peer_state = %Entity.Server{
      actor_id: "thread:sess-1",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "bogus", %{})
    assert result["ok"] == false
    assert String.contains?(result["error"]["message"], "unknown tool")
  end

  test "_echo tool requires chat_id in thread state" do
    peer_state = %Entity.Server{
      actor_id: "thread:sess-1",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "_echo", %{"nonce" => "abc"})
    assert result["ok"] == false
  end

  test "_echo tool synthesises reply from nonce when chat_id present" do
    peer_state = %Entity.Server{
      actor_id: "thread:sess-1",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{"chat_id" => "oc_echo"}
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "_echo", %{"nonce" => "nonce-1"})
    assert result["ok"] == true
  end
end
