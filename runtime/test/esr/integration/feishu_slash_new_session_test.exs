defmodule Esr.Integration.FeishuSlashNewSessionTest do
  @moduledoc """
  PR-8 T3 — Full Feishu `/new-session` flow, end-to-end.

  Simulates:

    1. User DMs bot: envelope with `content_text`
       `"/new-session --agent cc --dir /tmp/t3-int"`, `chat_id "oc_slashsession"`,
       `thread_id "om_slashsession"`.
    2. FeishuChatProxy detects the slash (via a direct send to the
       SlashHandler, mirroring `FeishuChatProxy.handle_upstream/2`'s
       `send(slash_pid, {:slash_cmd, envelope, self()})`).
    3. SlashHandler parses, emits `session_new` with `chat_id`/`thread_id`.
    4. `Session.New` creates the session **and** registers it in
       `SessionRegistry` — this is the T3 loop-closing behaviour.
    5. A second inbound envelope for the same `chat_id`/`thread_id` now
       resolves to the newly-created session via
       `SessionRegistry.lookup_by_chat_thread/2` — proving the binding loop.

  The integration test uses the production SlashHandler started by
  `Esr.AdminSession.bootstrap_slash_handler/0` (PR-8 T1). No stubs — the
  full command path runs through `Esr.Admin.Dispatcher` → `Session.New`.

  ## PR-8 T4 update

  Post-T4, `Session.New` delegates the chat-bound branch to
  `Esr.SessionRouter.create_session/1`, which spawns the full
  `pipeline.inbound` (FeishuChatProxy, CCProxy, CCProcess, TmuxProcess)
  and registers the session with refs carrying each spawned peer pid.
  This test still asserts the T3 invariant (`lookup_by_chat_thread/2`
  returns the newly-created session); the T4-specific assertion —
  that `refs.feishu_chat_proxy` is a live pid — lives in
  `Esr.Admin.Commands.Session.NewTest`'s `:t4_session_router` describe
  block rather than here, to keep each test focused.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]
  import Esr.TestSupport.TmuxIsolation, only: [isolated_tmux_socket: 1]

  alias Esr.Peers.SlashHandler

  @test_principal "ou_t3_flow"
  @chat_id "oc_slashsession"
  @thread_id "om_slashsession"

  setup :assert_with_grants
  setup :wipe_sessions_on_exit
  # PR-8 T4: Session.New now routes through SessionRouter, which spawns
  # the full pipeline — including TmuxProcess. Pin a throwaway socket so
  # the integration test doesn't touch the user's default tmux socket.
  setup :isolated_tmux_socket

  setup %{tmux_socket: sock} do
    ensure_admin_dispatcher()
    assert is_pid(Process.whereis(Esr.Admin.Dispatcher))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../fixtures/agents/simple.yaml", __DIR__)
      )

    # PR-8 T4: SessionRouter must be up for the chat-bound Session.New
    # path to succeed. The router is not (yet) an Esr.Application child,
    # so tests stand it up under the ExUnit supervisor when absent.
    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    # TmuxProcess.spawn_args/1 picks up :tmux_socket_override from app
    # env when no explicit :tmux_socket is threaded through — Session.New
    # has no dedicated tmux_socket arg, so route via the app env.
    prior_tmux_override = Application.get_env(:esr, :tmux_socket_override)
    Application.put_env(:esr, :tmux_socket_override, sock)

    on_exit(fn ->
      case prior_tmux_override do
        nil -> Application.delete_env(:esr, :tmux_socket_override)
        v -> Application.put_env(:esr, :tmux_socket_override, v)
      end
    end)

    :ok = Esr.TestSupport.Grants.with_grants(%{@test_principal => ["*"]})

    # PR-8 T1: SlashHandler is auto-started by
    # `Esr.AdminSession.bootstrap_slash_handler/0` at application boot,
    # so we only need to re-spawn if a sibling torched it.
    slash_pid =
      case Esr.AdminSessionProcess.slash_handler_ref() do
        {:ok, pid} ->
          pid

        :error ->
          {:ok, pid} =
            start_supervised(%{
              id: :t3_slash_handler,
              start:
                {SlashHandler, :start_link,
                 [%{session_id: "admin", neighbors: [], proxy_ctx: %{}}]}
            })

          pid
      end

    on_exit(fn ->
      Esr.SessionRegistry.lookup_by_chat_thread(@chat_id, @thread_id)
      |> case do
        {:ok, sid, _} -> Esr.SessionRegistry.unregister_session(sid)
        _ -> :ok
      end
    end)

    {:ok, slash: slash_pid}
  end

  test "slash /new-session binds session in SessionRegistry; 2nd inbound resolves to it" do
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    # Step 1: inbound slash envelope, shaped as FeishuChatProxy would build it.
    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session --agent cc --dir /tmp/t3-int",
        "chat_id" => @chat_id,
        "thread_id" => @thread_id
      }
    }

    # Step 2 + 3 + 4: FeishuChatProxy→SlashHandler→Dispatcher→Session.New.
    send(slash, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 2_000

    assert text =~ "session started:",
           "expected session-started reply, got: #{inspect(text)}"

    [_, sid] = Regex.run(~r/session started: (\S+)/, text)

    # Step 5: a second inbound for the same (chat_id, thread_id) resolves
    # to the newly-created session — the binding loop is closed.
    assert {:ok, ^sid, refs} =
             Esr.SessionRegistry.lookup_by_chat_thread(@chat_id, @thread_id),
           "SessionRegistry.lookup_by_chat_thread/2 must return the session " <>
             "created by the slash command"

    assert is_map(refs)

    # SessionProcess actually stored the chat_thread_key too (T2 behaviour,
    # double-checked here so T3 failures are easy to diagnose).
    state = Esr.SessionProcess.state(sid)
    assert state.chat_thread_key == %{chat_id: @chat_id, thread_id: @thread_id}
    assert state.metadata.principal_id == @test_principal
  end

  # Borrowed from Esr.Integration.NewSessionSmokeTest — tests that restart
  # the Admin.Supervisor may race against siblings.
  defp ensure_admin_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Admin.Supervisor)

      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Admin.Supervisor.start_link([])
      end
    end

    :ok
  end
end
