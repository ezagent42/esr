defmodule Esr.Integration.NewSessionSmokeTest do
  @moduledoc """
  P2-13: E2E smoke test for `/new-session esr-dev name=test root=/tmp/test-repo worktree=test`.

  Exercises the full PR-2 slash-command path end-to-end:

      FeishuChatProxy-style envelope
              |
              v
      Esr.Entity.SlashHandler  — parses the slash, casts session_new
              |
              v
      Esr.Admin.Dispatcher    — cap-checks (D18) + Tasks the command
              |
              v
      Esr.Commands.Scope.New       — validates args (D11/D13),
              |                              re-checks agent_def caps,
              |                              calls Scope.Supervisor
              v
      Esr.Scope.Supervisor  — starts Esr.Scope (Scope.Process +
                                 empty peers DynamicSupervisor)
              |
              v
      Reply relayed back to the originating "ChatProxy" (this test's
      pid) as `{:reply, "session started: <sid>"}`.

  Controlled failure mode (spec §P2-13): PR-2 does NOT yet spawn the
  pipeline peers (CCProcess, PtyProcess are PR-3 work). Session.init
  only brings up Scope.Process + an empty peers DynamicSupervisor,
  so the happy-path command succeeds and the peers sup is asserted
  childless. Future PR-3 work populates the pipeline from agent_def.

  Intentionally NOT tagged `:integration` per P2-13 task note: the
  whole path is pure Elixir + supervisor tree, no OS processes, so
  it runs in the default `mix test` profile.

  ## Drift from expansion doc

  P3-8 cleaned up the earlier drift: the SlashHandler's
  missing-capabilities format_result/1 clause now matches on the string
  `"missing_capabilities"` (matching `Session.New`'s actual emission),
  and the dispatcher's `session_new` permission is now
  `session:default/create` (canonical form). The text assertion below
  still accepts either `unauthorized` (dispatcher-level) or
  `missing_capabilities` (command-level) because the `ou_smoke_nocap`
  principal lacks every grant — the dispatcher rejects first.
  """
  use ExUnit.Case, async: false

  # PR-21κ Phase 6: tagged :integration because dispatch/3 enforces
  # workspace + user binding; setup writes to the global Workspaces /
  # Users registries, polluting other unit tests in the same VM.
  # Run via `mix test --include integration` for the full pipeline check.
  @moduletag :integration

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]

  alias Esr.Entity.SlashHandler

  @test_principal "ou_smoke_user"
  @test_principal_nocap "ou_smoke_nocap"

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

    # Test principal gets `"*"` (only grant shape that passes the
    # current bare-string-keyed matcher in
    # `Esr.Resource.Capability.Grants.matches?/2` for both the Dispatcher
    # check and the agent_def D18 check). A second principal gets
    # nothing so we can exercise the unauthorized branch. The prior
    # snapshot is restored on exit by `Esr.TestSupport.Grants`.
    :ok =
      Esr.TestSupport.Grants.with_grants(%{
        @test_principal => ["*"],
        @test_principal_nocap => []
      })

    # PR-8 T1: Esr.Entity.SlashHandler is now auto-started by
    # `Esr.Scope.Admin.bootstrap_slash_handler/0` during
    # `Esr.Application.start/2`, so no manual `start_supervised/1` is
    # needed here — the production path is the test path. Fall back to
    # a test-supervised spawn only if a prior test torched the handler
    # and nothing respawned it.
    slash_pid =
      case Esr.Scope.Admin.Process.slash_handler_ref() do
        {:ok, pid} ->
          pid

        :error ->
          {:ok, pid} =
            start_supervised(%{
              id: :smoke_slash_handler,
              start:
                {SlashHandler, :start_link,
                 [%{session_id: "admin", neighbors: [], proxy_ctx: %{}}]}
            })

          pid
      end

    # PR-21θ 2026-04-30: smoke test now uses real git infrastructure
    # because cwd= no longer auto-fills the dir from a literal arg.
    # Set up a tmp git repo with origin/main so `Esr.Worktree.add/3`
    # can succeed when triggered by `root= worktree=`.
    smoke_repo = Path.join(System.tmp_dir!(), "esr_smoke_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(smoke_repo)
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "init", "-q", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "commit", "--allow-empty", "-q", "-m", "init"])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "remote", "add", "origin", smoke_repo])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "fetch", "origin", "-q"])

    # PR-21κ Phase 6: dispatch/3 enforces requires_workspace_binding
    # for /new-session per slash-routes.yaml. Register an in-memory
    # workspace binding for the smoke chat so the precondition passes.
    test_app_id = "smoke_app_#{System.unique_integer([:positive])}"
    smoke_chat_id = "oc_smoke"

    workspace =
      Esr.Test.WorkspaceFixture.build(
        name: "esr-dev",
        owner: @test_principal,
        role: "dev",
        chats: [%{"chat_id" => smoke_chat_id, "app_id" => test_app_id}]
      )

    prior_ws =
      case Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, "esr-dev") do
        {:ok, id} ->
          case Esr.Resource.Workspace.Registry.get_by_id(id) do
            {:ok, ws} -> ws
            :not_found -> nil
          end

        :not_found ->
          nil
      end

    Esr.Resource.Workspace.Registry.put(workspace)

    # PR-21κ Phase 6: dispatch/3 also enforces requires_user_binding
    # for /new-session. Bind both test principals to esr users via
    # an in-memory snapshot.
    prior_users = Esr.Entity.User.Registry.list()

    Esr.Entity.User.Registry.load_snapshot(%{
      "smoke_user" => %Esr.Entity.User.Registry.User{
        username: "smoke_user",
        feishu_ids: [@test_principal]
      },
      "smoke_nocap_user" => %Esr.Entity.User.Registry.User{
        username: "smoke_nocap_user",
        feishu_ids: [@test_principal_nocap]
      }
    })

    on_exit(fn ->
      File.rm_rf!(smoke_repo)
      if prior_ws, do: Esr.Resource.Workspace.Registry.put(prior_ws)

      # Restore prior users snapshot (best-effort; cross-test pollution
      # bounded because this is async: false).
      restored =
        prior_users
        |> Enum.map(fn %Esr.Entity.User.Registry.User{username: u} = user -> {u, user} end)
        |> Map.new()

      Esr.Entity.User.Registry.load_snapshot(restored)
    end)

    {:ok, slash: slash_pid, smoke_repo: smoke_repo, app_id: test_app_id, chat_id: smoke_chat_id}
  end

  # Phase 6 colon-namespace cutover: /new-session is now a dead form.
  # The dispatcher returns a rename hint directing to /session:new.
  # The full session-creation E2E test will be re-implemented when
  # Esr.Commands.Session.New is shipped (follow-up phase).

  test "old /new-session returns deprecated-slash hint pointing to /session:new",
       %{app_id: app_id, chat_id: chat_id} do
    branch = "smoke-#{System.unique_integer([:positive])}"

    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session esr-dev name=test root=/tmp/x worktree=#{branch}",
        "args" => %{"app_id" => app_id, "chat_id" => chat_id},
        "chat_id" => chat_id,
        "thread_id" => "om_smoke"
      }
    }

    ref = SlashHandler.dispatch(envelope, self(), make_ref())

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "/session:new",
           "expected deprecated-slash hint mentioning /session:new, got: #{text}"
  end

  test "old /new-session (error variant) also returns deprecated-slash hint",
       %{app_id: app_id, chat_id: chat_id} do
    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session esr-dev cwd=/tmp/x",
        "args" => %{"app_id" => app_id, "chat_id" => chat_id},
        "chat_id" => chat_id,
        "thread_id" => "om_smoke"
      }
    }

    ref = SlashHandler.dispatch(envelope, self(), make_ref())

    assert_receive {:reply, text, ^ref}, 1_000
    assert text =~ "/session:new",
           "expected deprecated-slash hint, got: #{text}"
  end

  test "old /new-session (no-cap variant) also returns deprecated-slash hint",
       %{app_id: app_id, chat_id: chat_id} do
    envelope = %{
      "principal_id" => @test_principal_nocap,
      "payload" => %{
        "text" => "/new-session esr-dev name=y root=/tmp/y-repo worktree=y",
        "args" => %{"app_id" => app_id, "chat_id" => chat_id},
        "chat_id" => chat_id,
        "thread_id" => "om_smoke"
      }
    }

    ref = SlashHandler.dispatch(envelope, self(), make_ref())

    assert_receive {:reply, text, ^ref}, 1_000
    # Phase 6: /new-session is dead — dispatcher returns a rename hint
    # before any cap check or command execution.
    assert text =~ "/session:new",
           "expected deprecated-slash hint, got: #{text}"
  end

  # Borrowed verbatim from `Esr.Admin.DispatcherTest` — tests that
  # restart the whole Admin.Supervisor may race against siblings.
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
