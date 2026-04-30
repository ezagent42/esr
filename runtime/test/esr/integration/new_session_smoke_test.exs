defmodule Esr.Integration.NewSessionSmokeTest do
  @moduledoc """
  P2-13: E2E smoke test for `/new-session esr-dev name=test root=/tmp/test-repo worktree=test`.

  Exercises the full PR-2 slash-command path end-to-end:

      FeishuChatProxy-style envelope
              |
              v
      Esr.Peers.SlashHandler  — parses the slash, casts session_new
              |
              v
      Esr.Admin.Dispatcher    — cap-checks (D18) + Tasks the command
              |
              v
      Esr.Admin.Commands.Session.New       — validates args (D11/D13),
              |                              re-checks agent_def caps,
              |                              calls SessionsSupervisor
              v
      Esr.SessionsSupervisor  — starts Esr.Session (SessionProcess +
                                 empty peers DynamicSupervisor)
              |
              v
      Reply relayed back to the originating "ChatProxy" (this test's
      pid) as `{:reply, "session started: <sid>"}`.

  Controlled failure mode (spec §P2-13): PR-2 does NOT yet spawn the
  pipeline peers (CCProcess, TmuxProcess are PR-3 work). Session.init
  only brings up SessionProcess + an empty peers DynamicSupervisor,
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
  import Esr.TestSupport.TmuxIsolation, only: [isolated_tmux_socket: 1]

  alias Esr.Peers.SlashHandler

  @test_principal "ou_smoke_user"
  @test_principal_nocap "ou_smoke_nocap"

  setup :assert_with_grants
  setup :wipe_sessions_on_exit
  # PR-8 T4: the chat-bound /new-session path now spawns the real
  # pipeline (incl. TmuxProcess). Pin a throwaway tmux socket.
  setup :isolated_tmux_socket

  setup %{tmux_socket: sock} do
    # `Esr.Admin.Dispatcher` may have been torn down by a prior
    # dispatcher_test.exs that restarts the Admin.Supervisor — mirror
    # its `ensure_admin_dispatcher` shim so we're robust to ordering.
    ensure_admin_dispatcher()
    assert is_pid(Process.whereis(Esr.Admin.Dispatcher))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../fixtures/agents/simple.yaml", __DIR__)
      )

    # PR-8 T4: SessionRouter is required by the chat-bound Session.New
    # branch. Start it under ExUnit if the app hasn't.
    if Process.whereis(Esr.SessionRouter) == nil do
      start_supervised!(Esr.SessionRouter)
    end

    prior_tmux_override = Application.get_env(:esr, :tmux_socket_override)
    Application.put_env(:esr, :tmux_socket_override, sock)

    on_exit(fn ->
      case prior_tmux_override do
        nil -> Application.delete_env(:esr, :tmux_socket_override)
        v -> Application.put_env(:esr, :tmux_socket_override, v)
      end
    end)

    # Test principal gets `"*"` (only grant shape that passes the
    # current bare-string-keyed matcher in
    # `Esr.Capabilities.Grants.matches?/2` for both the Dispatcher
    # check and the agent_def D18 check). A second principal gets
    # nothing so we can exercise the unauthorized branch. The prior
    # snapshot is restored on exit by `Esr.TestSupport.Grants`.
    :ok =
      Esr.TestSupport.Grants.with_grants(%{
        @test_principal => ["*"],
        @test_principal_nocap => []
      })

    # PR-8 T1: Esr.Peers.SlashHandler is now auto-started by
    # `Esr.AdminSession.bootstrap_slash_handler/0` during
    # `Esr.Application.start/2`, so no manual `start_supervised/1` is
    # needed here — the production path is the test path. Fall back to
    # a test-supervised spawn only if a prior test torched the handler
    # and nothing respawned it.
    slash_pid =
      case Esr.AdminSessionProcess.slash_handler_ref() do
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

    workspace = %Esr.Workspaces.Registry.Workspace{
      name: "esr-dev",
      owner: @test_principal,
      role: "dev",
      chats: [%{"chat_id" => smoke_chat_id, "app_id" => test_app_id}],
      metadata: %{}
    }

    prior_ws =
      case Esr.Workspaces.Registry.get("esr-dev") do
        {:ok, ws} -> ws
        :not_found -> nil
      end

    Esr.Workspaces.Registry.put(workspace)

    # PR-21κ Phase 6: dispatch/3 also enforces requires_user_binding
    # for /new-session. Bind both test principals to esr users via
    # an in-memory snapshot.
    prior_users = Esr.Users.Registry.list()

    Esr.Users.Registry.load_snapshot(%{
      "smoke_user" => %Esr.Users.Registry.User{
        username: "smoke_user",
        feishu_ids: [@test_principal]
      },
      "smoke_nocap_user" => %Esr.Users.Registry.User{
        username: "smoke_nocap_user",
        feishu_ids: [@test_principal_nocap]
      }
    })

    on_exit(fn ->
      File.rm_rf!(smoke_repo)
      if prior_ws, do: Esr.Workspaces.Registry.put(prior_ws)

      # Restore prior users snapshot (best-effort; cross-test pollution
      # bounded because this is async: false).
      restored =
        prior_users
        |> Enum.map(fn %Esr.Users.Registry.User{username: u} = user -> {u, user} end)
        |> Map.new()

      Esr.Users.Registry.load_snapshot(restored)
    end)

    {:ok, slash: slash_pid, smoke_repo: smoke_repo, app_id: test_app_id, chat_id: smoke_chat_id}
  end

  test "/new-session esr-dev name=test root=<tmp> worktree=test succeeds through the full slash path",
       %{smoke_repo: smoke_repo, app_id: app_id, chat_id: chat_id} do
    # PR-21θ 2026-04-30: cwd= removed from slash grammar; derived as
    # `<root>/.worktrees/<branch>`. This smoke test exercises the full
    # slash → cap check → worktree creation → session spawn path.
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()
    branch = "smoke-#{System.unique_integer([:positive])}"

    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session esr-dev name=test root=#{smoke_repo} worktree=#{branch}",
        "args" => %{"app_id" => app_id, "chat_id" => chat_id},
        "chat_id" => chat_id,
        "thread_id" => "om_smoke"
      }
    }

    # PR-21κ Phase 6: dispatch/3 (yaml-driven) replaces the legacy
    # `:slash_cmd` send. Reply lands ref-tagged.
    ref = SlashHandler.dispatch(envelope, self(), make_ref())

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "session started:", "expected session-started reply, got: #{text}"

    # Extract the session_id from "session started: <sid>".
    [_, sid] = Regex.run(~r/session started: (\S+)/, text)

    # SessionProcess came up with the expected args.
    state = Esr.SessionProcess.state(sid)
    assert state.agent_name == "cc"
    # PR-21θ: dir = derived cwd = <root>/.worktrees/<branch>
    assert state.dir == Path.join([smoke_repo, ".worktrees", branch])
    assert state.metadata.principal_id == @test_principal

    # PR-8 T4 update: the chat-bound /new-session path now routes through
    # SessionRouter.create_session/1, which spawns the full pipeline.inbound
    # (FeishuChatProxy, CCProcess, TmuxProcess; CCProxy is a stateless
    # module). The Session's peers DynamicSupervisor therefore carries the
    # three Stateful peers.
    peers_sup = Esr.Session.supervisor_name(sid)
    assert DynamicSupervisor.count_children(peers_sup).active == 3
  end

  test "/new-session without --agent returns a readable error reply",
       %{app_id: app_id, chat_id: chat_id} do
    {:ok, _slash} = Esr.AdminSessionProcess.slash_handler_ref()

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
    # PR-21κ: dispatch's `parse_route_args` rejects required-arg miss
    # for `name`. Pre-PR-21κ the legacy parser also rejected `cwd=`
    # explicitly — both paths surface a hint at user-typed keys.
    assert text =~ "name",
           "expected name missing error, got: #{text}"
  end

  test "/new-session without matching capability returns an error reply",
       %{app_id: app_id, chat_id: chat_id} do
    {:ok, _slash} = Esr.AdminSessionProcess.slash_handler_ref()

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

    # Dispatcher rejects the cast before Session.New runs (see
    # module-level "Drift from expansion doc"); text carries the
    # Dispatcher's "unauthorized" marker rather than AgentNew's
    # "missing_capabilities". Either way, the user gets a structured
    # error — never a crash — which is the spec §P2-13 intent.
    assert text =~ "error:", "expected an error reply, got: #{text}"

    assert text =~ "unauthorized" or text =~ "missing_capabilities",
           "expected unauthorized/missing_capabilities, got: #{text}"
  end

  # Borrowed verbatim from `Esr.Admin.DispatcherTest` — tests that
  # restart the whole Admin.Supervisor may race against siblings.
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
