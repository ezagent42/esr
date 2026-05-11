defmodule Esr.Session.LifecycleObserverTest do
  @moduledoc """
  Unit tests for `Esr.Session.LifecycleObserver` + `LifecycleObservers`.

  We use a stub "supervisor" pid (just a spawned Task that sleeps until
  killed) — the observer monitors any pid, it doesn't actually care
  about supervisor semantics. The contract under test is:

    * On DOWN, the observer calls `FAA.reply_chat_error/4` with kind
      `:session_terminated`.
    * On DOWN, the observer calls
      `ChatRouting.Registry.detach_session/3` for the (chat_id, app_id,
      sid) tuple.
    * The observer exits :normal after handling.

  Plan: PR-3 Task 3.7.
  """

  use ExUnit.Case, async: false

  alias Esr.Session.LifecycleObserver
  alias Esr.Session.LifecycleObservers

  setup do
    # LifecycleObservers DynSup is started by app boot — reuse rather
    # than start_supervised to avoid :already_started.
    assert is_pid(Process.whereis(LifecycleObservers))
    assert is_pid(Process.whereis(Esr.Session.ChatRouting.Registry))

    # Per-test sids/chats so ETS rows don't collide.
    sid = "lifecycle-obs-#{System.unique_integer([:positive])}"
    chat = "oc_lo_#{System.unique_integer([:positive])}"
    app = "app_lo_#{System.unique_integer([:positive])}"

    {:ok, sid: sid, chat: chat, app: app}
  end

  describe "DOWN behaviour" do
    test "detaches the chat-routing entry when monitored pid dies",
         %{sid: sid, chat: chat, app: app} do
      # Arrange: attach the sid to a chat slot so we can observe the
      # detach.
      :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)
      assert {:ok, ^sid} = Esr.Session.ChatRouting.Registry.current_session(chat, app)

      # Spawn a stub "supervisor" pid for the observer to monitor.
      sup_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Start an observer.
      {:ok, obs_pid} =
        LifecycleObservers.start_observer(%{
          session_id: sid,
          session_sup_pid: sup_pid,
          chat_id: chat,
          app_id: app
        })

      assert Process.alive?(obs_pid)

      # Act: kill the stub supervisor — the observer's monitor fires.
      ref = Process.monitor(obs_pid)
      Process.exit(sup_pid, :kill)

      # Wait for the observer to exit (:normal after handling DOWN).
      assert_receive {:DOWN, ^ref, :process, ^obs_pid, :normal}, 1_000

      # Assert: the chat-routing entry is gone.
      assert :not_found = Esr.Session.ChatRouting.Registry.current_session(chat, app)
    end

    test "exits :normal even when no FAA is registered for the app_id",
         %{sid: sid, chat: chat, app: app} do
      # No FAA registered for app_id — FAA.reply_chat_error/4 logs +
      # returns :ok. Observer must still exit :normal.
      :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)
      sup_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, obs_pid} =
        LifecycleObservers.start_observer(%{
          session_id: sid,
          session_sup_pid: sup_pid,
          chat_id: chat,
          app_id: app
        })

      ref = Process.monitor(obs_pid)
      Process.exit(sup_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^obs_pid, :normal}, 1_000
    end
  end

  describe "start_link/1 validation" do
    test "accepts a well-formed args map" do
      sup_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, obs_pid} =
               LifecycleObserver.start_link(%{
                 session_id: "s1",
                 session_sup_pid: sup_pid,
                 chat_id: "c1",
                 app_id: "a1"
               })

      assert Process.alive?(obs_pid)
      Process.exit(sup_pid, :kill)
    end

    test "raises FunctionClauseError on missing fields" do
      assert_raise FunctionClauseError, fn ->
        LifecycleObserver.start_link(%{session_id: "s1"})
      end
    end
  end
end
