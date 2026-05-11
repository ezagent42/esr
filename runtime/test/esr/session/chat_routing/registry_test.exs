defmodule Esr.Session.ChatRouting.RegistryTest do
  @moduledoc """
  Targeted unit tests for `Esr.Session.ChatRouting.Registry` — the
  `(chat_id, app_id) → {current, attached}` slot store.

  Most attach/detach behaviour is exercised indirectly via
  `Esr.Commands.Session.*` tests and integration tests; this file
  exists to pin the `set_current_session/3` semantics that landed
  alongside the `/session:switch` chat-bound clause (Phase B
  post-review fixes, spec rev-4 §4.2 row 3).
  """

  use ExUnit.Case, async: false

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  setup do
    case Process.whereis(ChatRouting) do
      nil -> start_supervised!(ChatRouting)
      _ -> :ok
    end

    :ok
  end

  describe "set_current_session/3" do
    test "promotes an attached UUID to current without changing the attached set" do
      chat = "oc_set_current_test_a"
      app = "esr_helper_set_current_a"
      sid_a = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
      sid_b = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

      :ok = ChatRouting.attach_session(chat, app, sid_a)
      :ok = ChatRouting.attach_session(chat, app, sid_b)

      # First-attach-wins: sid_a is current.
      assert {:ok, ^sid_a} = ChatRouting.current_session(chat, app)

      assert :ok = ChatRouting.set_current_session(chat, app, sid_b)
      assert {:ok, ^sid_b} = ChatRouting.current_session(chat, app)

      # Both sessions remain attached — switch ≠ detach.
      assert Enum.sort(ChatRouting.list_sessions(chat, app)) == Enum.sort([sid_a, sid_b])
    end

    test "is idempotent when the UUID is already current" do
      chat = "oc_set_current_test_b"
      app = "esr_helper_set_current_b"
      sid = "cccccccc-3333-4333-8333-cccccccccccc"

      :ok = ChatRouting.attach_session(chat, app, sid)
      assert {:ok, ^sid} = ChatRouting.current_session(chat, app)

      assert :ok = ChatRouting.set_current_session(chat, app, sid)
      assert {:ok, ^sid} = ChatRouting.current_session(chat, app)
    end

    test "returns {:error, :not_attached} when the UUID is not in the attached set" do
      chat = "oc_set_current_test_c"
      app = "esr_helper_set_current_c"
      sid_a = "dddddddd-4444-4444-8444-dddddddddddd"
      sid_ghost = "eeeeeeee-5555-4555-8555-eeeeeeeeeeee"

      :ok = ChatRouting.attach_session(chat, app, sid_a)

      assert {:error, :not_attached} =
               ChatRouting.set_current_session(chat, app, sid_ghost)

      # Current is unchanged.
      assert {:ok, ^sid_a} = ChatRouting.current_session(chat, app)
    end

    test "returns {:error, :not_attached} when the chat slot does not exist at all" do
      chat = "oc_set_current_test_d_unknown"
      app = "esr_helper_set_current_d"
      sid = "ffffffff-6666-4666-8666-ffffffffffff"

      assert {:error, :not_attached} =
               ChatRouting.set_current_session(chat, app, sid)
    end
  end

  describe "detach_session_by_id/1" do
    test "is a no-op when the sid is registered nowhere" do
      assert :ok = ChatRouting.detach_session_by_id("aaaa1111-7777-4777-8777-aaaa11117777")
    end

    test "detaches sid from a single-session slot and removes the row entirely" do
      chat = "oc_detach_test_a"
      app = "esr_helper_detach_a"
      sid = "ababab11-7777-4777-8777-ababab117777"

      :ok = ChatRouting.attach_session(chat, app, sid)
      assert {:ok, ^sid} = ChatRouting.current_session(chat, app)

      assert :ok = ChatRouting.detach_session_by_id(sid)

      # Row should be gone entirely once attached/current both empty.
      assert :not_found = ChatRouting.current_session(chat, app)
      assert [] = ChatRouting.list_sessions(chat, app)
    end

    test "detaches a non-current sid without changing current" do
      chat = "oc_detach_test_b"
      app = "esr_helper_detach_b"
      sid_a = "abab1111-7777-4777-8777-abab11117777"
      sid_b = "abab2222-7777-4777-8777-abab22227777"

      :ok = ChatRouting.attach_session(chat, app, sid_a)
      :ok = ChatRouting.attach_session(chat, app, sid_b)
      assert {:ok, ^sid_a} = ChatRouting.current_session(chat, app)

      assert :ok = ChatRouting.detach_session_by_id(sid_b)
      assert {:ok, ^sid_a} = ChatRouting.current_session(chat, app)
      assert ChatRouting.list_sessions(chat, app) == [sid_a]
    end

    test "promotes a remaining attached sid when current is detached" do
      chat = "oc_detach_test_c"
      app = "esr_helper_detach_c"
      sid_a = "abab1111-8888-4888-8888-abab11118888"
      sid_b = "abab2222-8888-4888-8888-abab22228888"

      :ok = ChatRouting.attach_session(chat, app, sid_a)
      :ok = ChatRouting.attach_session(chat, app, sid_b)
      assert {:ok, ^sid_a} = ChatRouting.current_session(chat, app)

      assert :ok = ChatRouting.detach_session_by_id(sid_a)
      assert {:ok, ^sid_b} = ChatRouting.current_session(chat, app)
      assert ChatRouting.list_sessions(chat, app) == [sid_b]
    end

    test "removes the sid from multiple chat scopes" do
      chat_x = "oc_detach_test_d_x"
      chat_y = "oc_detach_test_d_y"
      app = "esr_helper_detach_d"
      sid = "abab3333-9999-4999-8999-abab33339999"

      :ok = ChatRouting.attach_session(chat_x, app, sid)
      :ok = ChatRouting.attach_session(chat_y, app, sid)

      assert :ok = ChatRouting.detach_session_by_id(sid)
      assert :not_found = ChatRouting.current_session(chat_x, app)
      assert :not_found = ChatRouting.current_session(chat_y, app)
    end
  end
end
