defmodule Esr.Commands.Session.UnbindChatTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Session.UnbindChat
  alias Esr.Session.ChatRouting.Registry, as: ChatScopeRegistry

  @submitter "user-uuid-0000-0000-000000000020"

  setup do
    # PR-3 (URI identity): URI store now backs Session entity rows.
    case Process.whereis(Esr.Uri.Store) do
      nil -> start_supervised!(Esr.Uri.Store)
      _ -> :ok
    end

    case Process.whereis(ChatScopeRegistry) do
      nil -> start_supervised!(ChatScopeRegistry)
      _ -> :ok
    end

    # Use per-test random chat slot so tests don't share attach state
    chat_id = "chat-unbind-chat-#{:rand.uniform(9_999_999)}"
    app_id = "app-unbind-chat-#{:rand.uniform(9_999_999)}"

    data_dir = Esr.Paths.runtime_home()

    {:ok, sid} =
      Esr.Uri.Compat.create_session(data_dir, %{
        name: "unbind-chat-test-session-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    :ok = ChatScopeRegistry.attach_session(chat_id, app_id, sid)
    {:ok, session_id: sid, chat_id: chat_id, app_id: app_id}
  end

  # ---------------------------------------------------------------------------
  # Happy path: implicit (current session)
  # ---------------------------------------------------------------------------

  test "success: /session:unbind-chat — unbinds current session when no session arg given", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:ok, result} = UnbindChat.execute(cmd)
    assert result["session_id"] == sid
    assert result["detached"] == true
  end

  test "success: /session:unbind-chat — new_current is nil when last session unbound", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    {:ok, result} = UnbindChat.execute(cmd)
    assert result["new_current"] == nil
  end

  test "success: /session:unbind-chat — new_current reflects next session when multiple attached" do
    data_dir = Esr.Paths.runtime_home()

    {:ok, sid1} =
      Esr.Uri.Compat.create_session(data_dir, %{
        name: "multi-s1-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    {:ok, sid2} =
      Esr.Uri.Compat.create_session(data_dir, %{
        name: "multi-s2-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    chat_id = "chat-multi-#{:rand.uniform(9_999_999)}"
    app_id = "app-multi-#{:rand.uniform(9_999_999)}"

    :ok = ChatScopeRegistry.attach_session(chat_id, app_id, sid1)
    :ok = ChatScopeRegistry.attach_session(chat_id, app_id, sid2)

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid1, "chat_id" => chat_id, "app_id" => app_id}
    }

    {:ok, result} = UnbindChat.execute(cmd)
    assert result["detached"] == true
    assert result["new_current"] == sid2
  end

  # ---------------------------------------------------------------------------
  # Happy path: explicit UUID arg
  # ---------------------------------------------------------------------------

  test "success: /session:unbind-chat — unbinds explicit UUID", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:ok, result} = UnbindChat.execute(cmd)
    assert result["session_id"] == sid
  end

  # ---------------------------------------------------------------------------
  # UUID-only contract (Phase 5 D2 + D5)
  # ---------------------------------------------------------------------------

  test "error: /session:unbind-chat — name input returns invalid_session_uuid", %{
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => "my-session-name", "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "invalid_session_uuid"}} = UnbindChat.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # No current session
  # ---------------------------------------------------------------------------

  test "error: /session:unbind-chat — no_current_session when chat slot empty" do
    chat_id = "chat-empty-#{:rand.uniform(9_999_999)}"
    app_id = "app-empty-#{:rand.uniform(9_999_999)}"

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "no_current_session"}} = UnbindChat.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Missing chat context
  # ---------------------------------------------------------------------------

  test "error: /session:unbind-chat — missing chat context returns invalid_args" do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{}
    }

    assert {:error, %{"type" => "invalid_args"}} = UnbindChat.execute(cmd)
  end
end
