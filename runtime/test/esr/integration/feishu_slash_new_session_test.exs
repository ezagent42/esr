defmodule Esr.Integration.FeishuSlashNewSessionTest do
  @moduledoc """
  PR-8 T3 — Full Feishu `/new-session` flow, end-to-end.

  Simulates:

    1. User DMs bot: envelope with `content_text`
       `"/new-session esr-dev name=t3"`, `chat_id "oc_slashsession"`,
       `thread_id "om_slashsession"`.
    2. FeishuChatProxy detects the slash (via a direct send to the
       SlashHandler, mirroring `FeishuChatProxy.handle_upstream/2`'s
       `send(slash_pid, {:slash_cmd, envelope, self()})`).
    3. SlashHandler parses, emits `session_new` with `chat_id`/`thread_id`.
    4. `Session.New` creates the session **and** registers it in
       `SessionRegistry` — this is the T3 loop-closing behaviour.
    5. A second inbound envelope for the same `chat_id`/`thread_id` now
       resolves to the newly-created session via
       `SessionRegistry.lookup_by_chat_thread/3` — proving the binding loop.

  The integration test uses the production SlashHandler started by
  `Esr.Scope.Admin.bootstrap_slash_handler/0` (PR-8 T1). No stubs — the
  full command path runs through `Esr.Admin.Dispatcher` → `Session.New`.

  ## PR-8 T4 update

  Post-T4, `Session.New` delegates the chat-bound branch to
  `Esr.Scope.Router.create_session/1`, which spawns the full
  `pipeline.inbound` (FeishuChatProxy, CCProxy, CCProcess, PtyProcess)
  and registers the session with refs carrying each spawned peer pid.
  This test still asserts the T3 invariant (`lookup_by_chat_thread/3`
  returns the newly-created session); the T4-specific assertion —
  that `refs.feishu_chat_proxy` is a live pid — lives in
  `Esr.Commands.Scope.NewTest`'s `:t4_session_router` describe
  block rather than here, to keep each test focused.
  """
  use ExUnit.Case, async: false

  # PR-21κ Phase 6: tagged :integration — dispatch/3 enforces workspace +
  # user binding; setup writes to global Workspaces / Users registries.
  @moduletag :integration

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]

  alias Esr.Entity.SlashHandler

  @test_principal "ou_t3_flow"
  @chat_id "oc_slashsession"
  @thread_id "om_slashsession"

  setup :assert_with_grants
  setup :wipe_sessions_on_exit

  setup do
    ensure_admin_dispatcher()
    assert is_pid(Process.whereis(Esr.Admin.Dispatcher))

    :ok =
      Esr.Entity.Agent.Registry.load_agents(
        Path.expand("../fixtures/agents/simple.yaml", __DIR__)
      )

    if Process.whereis(Esr.Scope.Router) == nil do
      start_supervised!(Esr.Scope.Router)
    end

    :ok = Esr.TestSupport.Grants.with_grants(%{@test_principal => ["*"]})

    # PR-8 T1: SlashHandler is auto-started by
    # `Esr.Scope.Admin.bootstrap_slash_handler/0` at application boot,
    # so we only need to re-spawn if a sibling torched it.
    slash_pid =
      case Esr.Scope.Admin.Process.slash_handler_ref() do
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
      # PR-A T1: Scope.Router defaults app_id to "default" when the
      # slash flow doesn't carry one (T3 will surface app_id explicitly).
      Esr.Resource.ChatScope.Registry.lookup_by_chat(@chat_id, "default")
      |> case do
        {:ok, sid, _} -> Esr.Resource.ChatScope.Registry.unregister_session(sid)
        _ -> :ok
      end
    end)

    # PR-21θ 2026-04-30: tmp git repo so `root= worktree=` succeeds.
    smoke_repo = Path.join(System.tmp_dir!(), "feishu_slash_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(smoke_repo)
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "init", "-q", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "commit", "--allow-empty", "-q", "-m", "init"])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "remote", "add", "origin", smoke_repo])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "fetch", "origin", "-q"])

    on_exit(fn -> File.rm_rf!(smoke_repo) end)

    # PR-21κ Phase 6: dispatch/3 enforces requires_workspace_binding +
    # requires_user_binding for /new-session per slash-routes.yaml.
    # Set up an in-memory workspace + user for the test chat so the
    # preconditions pass. These pre-existed at the legacy `:slash_cmd`
    # path's level (it had no gates), so this setup is new for the
    # production-equivalent dispatch path.
    test_app_id = "default"

    workspace = %Esr.Resource.Workspace.Registry.Workspace{
      name: "esr-dev",
      owner: "t3_user",
      role: "dev",
      chats: [%{"chat_id" => @chat_id, "app_id" => test_app_id}],
      metadata: %{}
    }

    Esr.Resource.Workspace.Registry.put(workspace)

    Esr.Entity.User.Registry.load_snapshot(%{
      "t3_user" => %Esr.Entity.User.Registry.User{
        username: "t3_user",
        feishu_ids: [@test_principal]
      }
    })

    {:ok, slash: slash_pid, smoke_repo: smoke_repo, app_id: test_app_id}
  end

  # Phase 6 colon-namespace cutover: /new-session is now a dead form.
  # The full E2E session-creation test will be re-implemented when
  # Esr.Commands.Session.New ships (follow-up phase).
  # For now, verify the old form returns a deprecated-slash hint.
  test "old /new-session returns deprecated-slash hint pointing to /session:new",
       %{smoke_repo: smoke_repo, app_id: app_id} do
    branch = "t3-#{System.unique_integer([:positive])}"

    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session esr-dev name=t3 root=#{smoke_repo} worktree=#{branch}",
        "args" => %{"app_id" => app_id, "chat_id" => @chat_id},
        "chat_id" => @chat_id,
        "thread_id" => @thread_id
      }
    }

    ref = Esr.Entity.SlashHandler.dispatch(envelope, self(), make_ref())

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "/session:new",
           "expected deprecated-slash hint mentioning /session:new, got: #{inspect(text)}"
  end

  # Borrowed from Esr.Integration.NewSessionSmokeTest — tests that restart
  # the Admin.Supervisor may race against siblings.
  defp ensure_admin_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Slash.Supervisor)

      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Slash.Supervisor.start_link([])
      end
    end

    :ok
  end
end
