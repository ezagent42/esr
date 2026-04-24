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

  ## Gap called out

  Current `Session.New` registers with an empty `refs` map because it
  calls `SessionsSupervisor.start_session/1` directly (the Session's peers
  DynamicSupervisor starts empty — pipeline peer spawning still lives in
  `SessionRouter.create_session/2`). This is enough to make the registry
  lookup _hit_ (step 5 above), but `FeishuAppAdapter.handle_upstream/2`
  will still fall through to the `other` clause because its pattern
  requires `%{feishu_chat_proxy: pid}`. Rewiring `Session.New` to go
  through `SessionRouter.create_session/2` (so the pipeline gets spawned
  and refs carry the real `feishu_chat_proxy` pid) is the obvious
  follow-up — this test asserts the registry binding only, which is what
  T3 is scoped to.
  """
  use ExUnit.Case, async: false

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]

  alias Esr.Peers.SlashHandler

  @test_principal "ou_t3_flow"
  @chat_id "oc_slashsession"
  @thread_id "om_slashsession"

  setup :assert_with_grants
  setup :wipe_sessions_on_exit

  setup do
    ensure_admin_dispatcher()
    assert is_pid(Process.whereis(Esr.Admin.Dispatcher))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../fixtures/agents/simple.yaml", __DIR__)
      )

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
