defmodule Esr.EntityServerSessionCleanupTest do
  @moduledoc """
  DI-11 Task 24 — `session.signal_cleanup` MCP tool.

  The tool is invoked by a CC session to report the outcome of its
  cleanup run (CLEANED / DIRTY / ...). `Esr.Entity.Server.build_emit_for_tool/3`
  routes the payload to `Esr.Admin.Dispatcher` via `send/2` — no
  adapter emit is broadcast, the caller just gets an immediate
  `{:ok, %{"acknowledged" => true}}` ack.

  Task 25 will teach `Esr.Admin.Dispatcher` what to do with
  `{:cleanup_signal, ...}`; today its catch-all `handle_info/2`
  swallows the message, which is fine for this task.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity

  # Swap the registered `Esr.Admin.Dispatcher` name for the current
  # test pid so `send(Esr.Admin.Dispatcher, ...)` lands in our mailbox.
  # The real dispatcher (started by the app supervisor) is temporarily
  # unregistered and re-registered on exit — `async: false` guarantees
  # no other test observes the swap.
  defp hijack_dispatcher_name do
    original = Process.whereis(Esr.Admin.Dispatcher)

    if original do
      Process.unregister(Esr.Admin.Dispatcher)
    end

    Process.register(self(), Esr.Admin.Dispatcher)

    on_exit(fn ->
      if Process.whereis(Esr.Admin.Dispatcher) == self() do
        Process.unregister(Esr.Admin.Dispatcher)
      end

      if original && Process.alive?(original) do
        Process.register(original, Esr.Admin.Dispatcher)
      end
    end)
  end

  test "session.signal_cleanup delivers {:cleanup_signal, ...} to Admin.Dispatcher" do
    hijack_dispatcher_name()

    peer_state = %Entity.Server{
      actor_id: "thread:sess-cleanup-1",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    args = %{
      "session_id" => "sess-abc",
      "worktree_path" => "/tmp/esr-wt/feat-x",
      "status" => "CLEANED",
      "details" => %{"files_removed" => 3}
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "session.signal_cleanup", args)

    assert result == %{"ok" => true, "acknowledged" => true}

    assert_receive {:cleanup_signal, "sess-abc", "CLEANED", %{"files_removed" => 3}}, 500
  end

  test "session.signal_cleanup defaults details to empty map when omitted" do
    hijack_dispatcher_name()

    peer_state = %Entity.Server{
      actor_id: "thread:sess-cleanup-2",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    args = %{
      "session_id" => "sess-xyz",
      "status" => "DIRTY"
    }

    result = Entity.Server.invoke_tool_for_test(peer_state, "session.signal_cleanup", args)

    assert result == %{"ok" => true, "acknowledged" => true}
    assert_receive {:cleanup_signal, "sess-xyz", "DIRTY", %{}}, 500
  end

  test "session.signal_cleanup is a no-op-ack when Dispatcher is not registered" do
    # If the dispatcher isn't up (e.g. during early boot) the tool must
    # still return an ack — we don't want CC sessions to hang / retry.
    original = Process.whereis(Esr.Admin.Dispatcher)

    if original do
      Process.unregister(Esr.Admin.Dispatcher)
    end

    on_exit(fn ->
      if original && Process.alive?(original) &&
           Process.whereis(Esr.Admin.Dispatcher) == nil do
        Process.register(original, Esr.Admin.Dispatcher)
      end
    end)

    peer_state = %Entity.Server{
      actor_id: "thread:sess-cleanup-3",
      actor_type: "feishu_thread_proxy",
      handler_module: "feishu_thread",
      state: %{}
    }

    result =
      Entity.Server.invoke_tool_for_test(peer_state, "session.signal_cleanup", %{
        "session_id" => "sess-orphan",
        "status" => "DIRTY"
      })

    assert result == %{"ok" => true, "acknowledged" => true}
  end
end
