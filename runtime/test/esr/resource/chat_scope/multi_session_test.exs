defmodule Esr.Resource.ChatScope.MultiSessionTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.ChatScope.Registry, as: ChatScope

  @chat "oc_multi_full"
  @app "cli_test"
  @uuid1 "aaaaaaaa-0001-4000-8000-000000000001"
  @uuid2 "aaaaaaaa-0002-4000-8000-000000000002"
  @uuid3 "aaaaaaaa-0003-4000-8000-000000000003"

  setup do
    unless Process.whereis(ChatScope), do: ChatScope.start_link([])
    # Clean slate for this chat key
    ChatScope.detach_session(@chat, @app, @uuid1)
    ChatScope.detach_session(@chat, @app, @uuid2)
    ChatScope.detach_session(@chat, @app, @uuid3)
    :ok
  end

  test "attach 2 sessions: both in attached, first attached = current" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)

    sessions = ChatScope.attached_sessions(@chat, @app) |> Enum.sort()
    assert sessions == Enum.sort([@uuid1, @uuid2])
    assert {:ok, @uuid1} = ChatScope.current_session(@chat, @app)
  end

  test "detach current: next remaining becomes current" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)
    ChatScope.detach_session(@chat, @app, @uuid1)

    assert {:ok, @uuid2} = ChatScope.current_session(@chat, @app)
    assert ChatScope.attached_sessions(@chat, @app) == [@uuid2]
  end

  test "detach non-current: current unchanged" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)
    assert {:ok, @uuid1} = ChatScope.current_session(@chat, @app)

    ChatScope.detach_session(@chat, @app, @uuid2)

    assert {:ok, @uuid1} = ChatScope.current_session(@chat, @app)
    assert ChatScope.attached_sessions(@chat, @app) == [@uuid1]
  end

  test "re-attach already-attached: idempotent (no duplicates)" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid1)

    assert length(ChatScope.attached_sessions(@chat, @app)) == 1
  end

  test "list sessions: returns all attached" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)
    ChatScope.attach_session(@chat, @app, @uuid3)

    result = ChatScope.attached_sessions(@chat, @app) |> Enum.sort()
    assert result == Enum.sort([@uuid1, @uuid2, @uuid3])
  end

  test "detach all: empty list + :not_found current" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.detach_session(@chat, @app, @uuid1)

    assert [] = ChatScope.attached_sessions(@chat, @app)
    assert :not_found = ChatScope.current_session(@chat, @app)
  end
end
