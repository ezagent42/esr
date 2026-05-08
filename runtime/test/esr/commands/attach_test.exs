defmodule Esr.Commands.AttachTest do
  @moduledoc """
  PR-22: `/attach` resolves the live session in the chat/thread and
  renders both an HTTP URL (clickable in Feishu) and the canonical
  `esr://` URI.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Attach
  alias Esr.Resource.ChatScope.Registry, as: SessionRegistry

  setup do
    # Use a unique chat triple per test so they don't collide.
    chat_id = "oc_attach_#{System.unique_integer([:positive])}"
    app_id = "app_attach_#{System.unique_integer([:positive])}"
    thread_id = chat_id
    {:ok, chat_id: chat_id, app_id: app_id, thread_id: thread_id}
  end

  test "returns clickable HTTP URL + canonical esr URI when session exists",
       %{chat_id: chat_id, app_id: app_id, thread_id: thread_id} do
    sid = "sess_attach_#{System.unique_integer([:positive])}"

    # Register a row via the actual API (ETS table is :protected — only
    # the SessionRegistry GenServer can write).
    :ok =
      SessionRegistry.register_session(
        sid,
        %{chat_id: chat_id, app_id: app_id, thread_id: thread_id},
        %{}
      )

    on_exit(fn -> SessionRegistry.unregister_session(sid) end)

    args = %{"chat_id" => chat_id, "app_id" => app_id, "thread_id" => thread_id}
    assert {:ok, %{"text" => text}} = Attach.execute(%{"args" => args})

    assert text =~ "esr://localhost/sessions/#{sid}/attach"
    assert text =~ "/sessions/#{sid}/attach"
  end

  test "returns helpful message when no live session in chat",
       %{chat_id: chat_id, app_id: app_id, thread_id: thread_id} do
    args = %{"chat_id" => chat_id, "app_id" => app_id, "thread_id" => thread_id}
    assert {:ok, %{"text" => text}} = Attach.execute(%{"args" => args})
    assert text =~ "no live session"
  end

  test "no-args clause returns non-empty text" do
    assert {:ok, %{"text" => text}} = Attach.execute(%{})
    assert is_binary(text)
    refute text == ""
  end
end
