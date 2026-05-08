defmodule Esr.Commands.Session.AttachTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Session.Attach
  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry
  alias Esr.Resource.Capability.Grants

  @submitter "user-uuid-0000-0000-000000000010"

  setup do
    # Session registry
    case Process.whereis(SessionRegistry) do
      nil -> start_supervised!(SessionRegistry)
      _ -> :ok
    end

    # ChatScope registry
    case Process.whereis(ChatScopeRegistry) do
      nil -> start_supervised!(ChatScopeRegistry)
      _ -> :ok
    end

    # PubSub — required by Grants.load_snapshot/1's broadcast_grants_changed/1
    case Process.whereis(EsrWeb.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: EsrWeb.PubSub})
      _ -> :ok
    end

    # Capability Grants GenServer
    case Process.whereis(Grants) do
      nil -> start_supervised!(Grants)
      _ -> :ok
    end

    # Per-test unique chat slot so tests don't share attach state
    chat_id = "chat-attach-#{:rand.uniform(9_999_999)}"
    app_id = "app-attach-#{:rand.uniform(9_999_999)}"

    # Seed a real session in the registry
    data_dir = Esr.Paths.runtime_home()

    {:ok, session_id} =
      SessionRegistry.create_session(data_dir, %{
        name: "attach-test-session-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    # Grant submitter the attach cap for this specific session
    :ok = Grants.load_snapshot(%{@submitter => ["session:#{session_id}/attach"]})

    on_exit(fn ->
      Grants.load_snapshot(%{})
    end)

    {:ok, session_id: session_id, chat_id: chat_id, app_id: app_id}
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "success: attaches session and returns result", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:ok, result} = Attach.execute(cmd)
    assert result["session_id"] == sid
    assert result["attached"] == true
  end

  test "success: session becomes current after attach", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    {:ok, _} = Attach.execute(cmd)
    assert {:ok, ^sid} = ChatScopeRegistry.current_session(chat_id, app_id)
  end

  # ---------------------------------------------------------------------------
  # UUID-only contract (Phase 5 D2 + D5)
  # ---------------------------------------------------------------------------

  test "error: name input instead of UUID returns invalid_session_uuid", %{
    chat_id: chat_id,
    app_id: app_id
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => "my-session-name", "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "invalid_session_uuid"}} = Attach.execute(cmd)
  end

  test "error: empty session arg returns invalid_args", %{chat_id: chat_id, app_id: app_id} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => "", "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "invalid_args"}} = Attach.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Session not found
  # ---------------------------------------------------------------------------

  test "error: unknown UUID returns unknown_session", %{chat_id: chat_id, app_id: app_id} do
    unknown = "ffffffff-ffff-4fff-bfff-ffffffffffff"

    # Grant cap for the unknown session so the cap check passes and we reach not-found
    :ok = Grants.load_snapshot(%{@submitter => ["session:#{unknown}/attach"]})

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => unknown, "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "unknown_session"}} = Attach.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Cap check rejection
  # ---------------------------------------------------------------------------

  test "error: submitter without cap returns not_authorized", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    # Clear all grants
    :ok = Grants.load_snapshot(%{})

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:error, %{"type" => "not_authorized"}} = Attach.execute(cmd)
  end

  test "success: admin cap is accepted in lieu of attach cap", %{
    session_id: sid,
    chat_id: chat_id,
    app_id: app_id
  } do
    :ok = Grants.load_snapshot(%{@submitter => ["session:#{sid}/admin"]})

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "chat_id" => chat_id, "app_id" => app_id}
    }

    assert {:ok, _} = Attach.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Missing chat context
  # ---------------------------------------------------------------------------

  test "error: missing chat context returns invalid_args", %{session_id: sid} do
    :ok = Grants.load_snapshot(%{@submitter => ["session:#{sid}/attach"]})

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid}
    }

    assert {:error, %{"type" => "invalid_args"}} = Attach.execute(cmd)
  end
end
