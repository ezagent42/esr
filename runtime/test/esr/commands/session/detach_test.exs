defmodule Esr.Commands.Session.DetachTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Session.Detach
  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry

  @submitter "user-uuid-0000-0000-000000000020"

  setup do
    case Process.whereis(SessionRegistry) do
      nil -> start_supervised!(SessionRegistry)
      _ -> :ok
    end

    case Process.whereis(ChatScopeRegistry) do
      nil -> start_supervised!(ChatScopeRegistry)
      _ -> :ok
    end

    # Use per-test random chat slot so tests don't share attach state
    chat_id = "chat-detach-#{:rand.uniform(9_999_999)}"
    app_id = "app-detach-#{:rand.uniform(9_999_999)}"

    data_dir = Esr.Paths.runtime_home()

    {:ok, sid} =
      SessionRegistry.create_session(data_dir, %{
        name: "detach-test-session-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    :ok = ChatScopeRegistry.attach_session(chat_id, app_id, sid)
    {:ok, session_id: sid, chat_id: chat_id, app_id: app_id}
  end

  # ---------------------------------------------------------------------------
  # Happy path: implicit (current session)
  # ---------------------------------------------------------------------------

  test "success: detaches current session when no session arg given", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:ok, result} = Detach.execute(cmd)
    assert result["session_id"] == sid
    assert result["detached"] == true
  end

  test "success: new_current is nil when last session detached", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    {:ok, result} = Detach.execute(cmd)
    assert result["new_current"] == nil
  end

  test "success: new_current reflects next session when multiple attached" do
    data_dir = Esr.Paths.runtime_home()

    {:ok, sid1} =
      SessionRegistry.create_session(data_dir, %{
        name: "multi-s1-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    {:ok, sid2} =
      SessionRegistry.create_session(data_dir, %{
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

    {:ok, result} = Detach.execute(cmd)
    assert result["detached"] == true
    assert result["new_current"] == sid2
  end

  # ---------------------------------------------------------------------------
  # Happy path: explicit UUID arg
  # ---------------------------------------------------------------------------

  test "success: detaches explicit UUID", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:ok, result} = Detach.execute(cmd)
    assert result["session_id"] == sid
  end

  # ---------------------------------------------------------------------------
  # UUID-only contract (Phase 5 D2 + D5)
  # ---------------------------------------------------------------------------

  test "error: name input returns invalid_session_uuid", %{chat_id: chat_id, app_id: app_id} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => "my-session-name", "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "invalid_session_uuid"}} = Detach.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # No current session
  # ---------------------------------------------------------------------------

  test "error: no_current_session when chat slot empty" do
    chat_id = "chat-empty-#{:rand.uniform(9_999_999)}"
    app_id = "app-empty-#{:rand.uniform(9_999_999)}"

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "no_current_session"}} = Detach.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Missing chat context
  # ---------------------------------------------------------------------------

  test "error: missing chat context returns invalid_args" do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{}
    }

    assert {:error, %{"type" => "invalid_args"}} = Detach.execute(cmd)
  end
end
