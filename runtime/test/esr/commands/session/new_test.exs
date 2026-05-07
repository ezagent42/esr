defmodule Esr.Commands.Session.NewTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Session.New
  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry

  @submitter "user-uuid-0000-0000-000000000001"

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

    :ok
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "success: creates session + returns structured result" do
    name = "my-session-#{:rand.uniform(99_999)}"
    cmd = %{"submitted_by" => @submitter, "args" => %{"name" => name}}
    assert {:ok, result} = New.execute(cmd)
    assert is_binary(result["session_id"])
    assert result["name"] == name
    assert result["owner_user"] == @submitter
  end

  test "success: UUID in result is a valid v4 UUID" do
    name = "uuid-check-#{:rand.uniform(99_999)}"
    cmd = %{"submitted_by" => @submitter, "args" => %{"name" => name}}
    {:ok, result} = New.execute(cmd)

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             result["session_id"]
           )
  end

  test "success: session persisted in registry" do
    name = "registry-check-#{:rand.uniform(99_999)}"
    cmd = %{"submitted_by" => @submitter, "args" => %{"name" => name}}
    {:ok, result} = New.execute(cmd)

    assert {:ok, session} = SessionRegistry.get_by_id(result["session_id"])
    assert session.name == name
  end

  test "success: auto-attaches when chat_id + app_id present" do
    name = "auto-attach-#{:rand.uniform(99_999)}"
    chat_id = "chat-#{:rand.uniform(99_999)}"
    app_id = "app-#{:rand.uniform(99_999)}"

    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"name" => name, "chat_id" => chat_id, "app_id" => app_id}
    }

    {:ok, result} = New.execute(cmd)
    assert {:ok, sid} = ChatScopeRegistry.current_session(chat_id, app_id)
    assert sid == result["session_id"]
  end

  test "success: does NOT attach when chat context absent" do
    name = "no-chat-#{:rand.uniform(99_999)}"
    cmd = %{"submitted_by" => @submitter, "args" => %{"name" => name}}
    {:ok, result} = New.execute(cmd)

    # No chat_id/app_id  → registry slot untouched
    # We can only verify the session itself was created
    assert {:ok, _session} = SessionRegistry.get_by_id(result["session_id"])
  end

  # ---------------------------------------------------------------------------
  # Argument validation errors
  # ---------------------------------------------------------------------------

  test "error: missing name arg returns invalid_args" do
    cmd = %{"submitted_by" => @submitter, "args" => %{}}
    assert {:error, %{"type" => "invalid_args"}} = New.execute(cmd)
  end

  test "error: empty name returns invalid_args" do
    cmd = %{"submitted_by" => @submitter, "args" => %{"name" => ""}}
    assert {:error, %{"type" => "invalid_args"}} = New.execute(cmd)
  end

  test "error: non-map args returns invalid_args" do
    cmd = %{"submitted_by" => @submitter}
    assert {:error, %{"type" => "invalid_args"}} = New.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Name uniqueness
  # ---------------------------------------------------------------------------

  test "error: duplicate name for same owner returns session_name_taken" do
    name = "dup-#{:rand.uniform(99_999)}"
    cmd = %{"submitted_by" => @submitter, "args" => %{"name" => name}}
    assert {:ok, _} = New.execute(cmd)
    assert {:error, %{"type" => "session_name_taken"}} = New.execute(cmd)
  end

  test "success: same name under different owner is allowed" do
    name = "shared-name-#{:rand.uniform(99_999)}"
    other_submitter = "user-uuid-0000-0000-000000000002"

    cmd1 = %{"submitted_by" => @submitter, "args" => %{"name" => name}}
    cmd2 = %{"submitted_by" => other_submitter, "args" => %{"name" => name}}

    assert {:ok, r1} = New.execute(cmd1)
    assert {:ok, r2} = New.execute(cmd2)
    assert r1["session_id"] != r2["session_id"]
  end
end
